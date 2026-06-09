import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers

enum GhosttyPasteboardHelper {
    private final class ClipboardWriteCapture {
        private let lock = NSLock()
        private var capturedValue: String?

        func capture(_ value: String) {
            lock.lock()
            capturedValue = value
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return capturedValue
        }
    }

    enum ImageFileMaterializationResult {
        case saved(URL)
        case noDecodableImagePayload
        case rejectedImagePayload
    }

    enum ImageFileListMaterializationResult {
        case saved([URL])
        case noDecodableImagePayload
        case rejectedImagePayload
    }

    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
    private static let temporaryImageFilenamePrefix = "clipboard-"
    private static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    private static let temporaryImageOwnershipLock = NSLock()
    private static var ownedTemporaryImagePaths: Set<String> = []
    private static let standardClipboardWriteCaptureLock = NSLock()
    private static var standardClipboardWriteCapture: ClipboardWriteCapture?

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []

        if (types.contains(.fileURL) || types.contains(.URL)),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        let hasImagePayload = hasImageData(in: pasteboard)
        let hasRTFDAttachmentPayload = types.contains(.rtfd)
        if hasImagePayload,
           let html = pasteboard.string(forType: .html),
           PasteboardTextFidelity.htmlHasNoVisibleText(html) {
            return nil
        }

        let plainText = plainTextContents(from: pasteboard)
        if hasImagePayload || hasRTFDAttachmentPayload {
            guard let richText = richTextContents(from: pasteboard) else {
                return nil
            }
            if let plainText,
               PasteboardTextFidelity.shouldPreferPlainText(plainText, overRichText: richText) {
                return plainText
            }
            return richText
        }

        if let plainText,
           PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss(plainText),
           types.contains(where: isRichTextType),
           let richText = richTextContents(from: pasteboard),
           PasteboardTextFidelity.shouldPreferRichText(richText, overPlainText: plainText) {
            return richText
        }

        // Match upstream Ghostty's fast plain-text path for normal text paste.
        // Large clipboard payloads often also advertise HTML/RTF variants, and
        // eagerly rendering those rich-text flavors makes Cmd-V much slower than
        // vanilla Ghostty before the bytes ever reach the PTY.
        if let plainText {
            return plainText
        }

        return richTextContents(from: pasteboard)
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return hasPasteableContents(in: pasteboard)
    }

    static func fallbackPlainTextContents(from pasteboard: NSPasteboard) -> String? {
        plainTextContents(from: pasteboard)
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        if location == GHOSTTY_CLIPBOARD_STANDARD {
            var capture: ClipboardWriteCapture?
            standardClipboardWriteCaptureLock.lock()
            capture = standardClipboardWriteCapture
            if capture != nil {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()

            if let capture {
                capture.capture(string)
                return
            }
        }

        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    @discardableResult
    static func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String? {
        let capture = ClipboardWriteCapture()
        standardClipboardWriteCaptureLock.lock()
        standardClipboardWriteCapture = capture
        standardClipboardWriteCaptureLock.unlock()

        defer {
            standardClipboardWriteCaptureLock.lock()
            if standardClipboardWriteCapture === capture {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()
        }

        guard action() else { return nil }
        return capture.value
    }

    static func escapeForShell(_ value: String) -> String {
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return shellSingleQuoted(value)
        }
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func attributedStringContents(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        let attributed = attributedString(
            from: pasteboard,
            type: type,
            documentType: documentType
        )

        let sanitized = attributed?.string
            .split(separator: objectReplacementCharacter, omittingEmptySubsequences: false)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let sanitized, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private static func richTextContents(from pasteboard: NSPasteboard) -> String? {
        if let htmlText = attributedStringContents(from: pasteboard, type: .html, documentType: .html) {
            return htmlText
        }
        if let rtfText = attributedStringContents(from: pasteboard, type: .rtf, documentType: .rtf) {
            return rtfText
        }
        return attributedStringContents(from: pasteboard, type: .rtfd, documentType: .rtfd)
    }

    private static func plainTextContents(from pasteboard: NSPasteboard) -> String? {
        let allTypes = pasteboard.types ?? []

        // Prefer UTF-8 plain text whenever available. Some apps — notably
        // Qt-based ones like Telegram Desktop — register
        // `com.apple.traditional-mac-plain-text` (Mac OS Roman, which cannot
        // represent non-Latin scripts) *before* the UTF-8 variants. Iterating
        // `pasteboard.types` in order then returns a lossy value where every
        // non-Latin character becomes "?". Fixes #2818.
        for preferred in [utf8PlainTextType, NSPasteboard.PasteboardType.string] {
            guard allTypes.contains(preferred) else { continue }
            guard let value = pasteboard.string(forType: preferred), !value.isEmpty else { continue }
            return value
        }

        for type in allTypes {
            if type == utf8PlainTextType || type == .string { continue }
            guard isPlainTextType(type) else { continue }
            guard let value = pasteboard.string(forType: type), !value.isEmpty else { continue }
            return value
        }

        return nil
    }

    private static func hasPasteableContents(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.URL) || types.contains(.html) || types.contains(.rtf) || types.contains(.rtfd) {
            return true
        }
        if types.contains(where: isPlainTextType) {
            return true
        }
        return hasImageData(in: pasteboard)
    }

    private static func isPlainTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string || type == utf8PlainTextType {
            return true
        }

        guard type != .html,
              type != .rtf,
              type != .rtfd,
              type != .fileURL,
              let utType = UTType(type.rawValue) else { return false }

        return utType.conforms(to: .plainText)
    }

    private static func isRichTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .html || type == .rtf || type == .rtfd
    }

    private static func attributedString(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        let data =
            pasteboard.data(forType: type)
            ?? pasteboard.string(forType: type)?.data(using: .utf8)
        guard let data else { return nil }

        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    private static func attributedString(
        from item: NSPasteboardItem,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        let data =
            item.data(forType: type)
            ?? item.string(forType: type)?.data(using: .utf8)
        guard let data else { return nil }

        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    private static func rtfdAttachmentImageRepresentations(
        from attributed: NSAttributedString
    ) -> [(data: Data, fileExtension: String)] {
        var results: [(data: Data, fileExtension: String)] = []
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }

            if let fileWrapper = attachment.fileWrapper,
               let data = fileWrapper.regularFileContents,
               let imageRepresentation = imageAttachmentRepresentation(
                data: data,
                preferredFilename: fileWrapper.preferredFilename
               ) {
                results.append(imageRepresentation)
            }
        }

        return results
    }

    private static func rtfdAttachmentImageRepresentations(
        in pasteboard: NSPasteboard
    ) -> [(data: Data, fileExtension: String)] {
        guard let attributed = attributedString(
            from: pasteboard,
            type: .rtfd,
            documentType: .rtfd
        ) else { return [] }
        return rtfdAttachmentImageRepresentations(from: attributed)
    }

    private static func rtfdAttachmentImageRepresentations(
        in item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        guard let attributed = attributedString(
            from: item,
            type: .rtfd,
            documentType: .rtfd
        ) else { return [] }
        return rtfdAttachmentImageRepresentations(from: attributed)
    }

    private static func imageAttachmentRepresentation(
        data: Data,
        preferredFilename: String?
    ) -> (data: Data, fileExtension: String)? {
        let pathExtension =
            (preferredFilename as NSString?)?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        if let type = !pathExtension.isEmpty ? UTType(filenameExtension: pathExtension) : nil,
           type.conforms(to: .image),
           let fileExtension = type.preferredFilenameExtension ?? nonEmpty(pathExtension) {
            if isTIFFType(type) {
                return normalizedPNGRepresentation(from: data)
            }
            return (data, fileExtension)
        }

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension else { return nil }
        if isTIFFType(type) {
            return normalizedPNGRepresentation(from: data)
        }
        return (data, fileExtension)
    }

    private static func imageDataRepresentation(
        data: Data,
        type: NSPasteboard.PasteboardType
    ) -> (data: Data, fileExtension: String)? {
        guard let utType = UTType(type.rawValue),
              utType.conforms(to: .image),
              let fileExtension = utType.preferredFilenameExtension,
              !fileExtension.isEmpty else { return nil }
        if isTIFFType(utType) {
            return normalizedPNGRepresentation(from: data)
        }
        return (data, fileExtension)
    }

    private static func isTIFFType(_ type: UTType) -> Bool {
        type == .tiff || type.conforms(to: .tiff)
    }

    private static func normalizedPNGRepresentation(from data: Data) -> (data: Data, fileExtension: String)? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (pngData, "png")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }

        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    private static func directImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        for type in pasteboard.types ?? [] {
            guard type != .png,
                  let imageData = pasteboard.data(forType: type),
                  let representation = imageDataRepresentation(data: imageData, type: type) else { continue }
            return representation
        }

        return nil
    }

    private static func directImageRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = item.data(forType: .png) {
            return (pngData, "png")
        }

        for type in item.types {
            guard type != .png,
                  let imageData = item.data(forType: type),
                  let representation = imageDataRepresentation(data: imageData, type: type) else { continue }
            return representation
        }

        return nil
    }

    private static func fallbackImageRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, fileExtension: String)? {
        for type in item.types {
            guard let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let data = item.data(forType: type),
                  let normalized = normalizedPNGRepresentation(from: data) else { continue }
            return normalized
        }
        return nil
    }

    private static func fallbackImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        guard hasImageData(in: pasteboard),
              let tiffData = NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return nil }
        return normalizedPNGRepresentation(from: tiffData)
    }

    private static func imageRepresentations(
        in item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        if let directImage = directImageRepresentation(in: item) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: item)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: item) {
            return [fallbackImage]
        }
        return []
    }

    private static func pasteboardFallbackImageRepresentations(
        for item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        guard let copiedItem = copiedPasteboardItem(from: item) else { return [] }

        let pasteboard = NSPasteboard(name: .init("cmux-single-image-item-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        guard pasteboard.writeObjects([copiedItem]) else { return [] }

        if let directImage = directImageRepresentation(in: pasteboard) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: pasteboard)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: pasteboard) {
            return [fallbackImage]
        }
        return []
    }

    private static func copiedPasteboardItem(from item: NSPasteboardItem) -> NSPasteboardItem? {
        let copiedItem = NSPasteboardItem()
        var copiedAnyType = false

        for type in item.types {
            if let data = item.data(forType: type) {
                copiedAnyType = copiedItem.setData(data, forType: type) || copiedAnyType
                continue
            }

            if let string = item.string(forType: type) {
                copiedAnyType = copiedItem.setString(string, forType: type) || copiedAnyType
            }
        }

        return copiedAnyType ? copiedItem : nil
    }

    private static func imageRepresentations(
        in pasteboard: NSPasteboard
    ) -> [(data: Data, fileExtension: String)] {
        let itemRepresentations = (pasteboard.pasteboardItems ?? [])
            .flatMap { item in
                let representations = imageRepresentations(in: item)
                if !representations.isEmpty {
                    return representations
                }
                return pasteboardFallbackImageRepresentations(for: item)
            }
        if !itemRepresentations.isEmpty {
            return itemRepresentations
        }
        if let directImage = directImageRepresentation(in: pasteboard) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: pasteboard)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: pasteboard) {
            return [fallbackImage]
        }
        return []
    }

    private static func materializeImageFileURLs(
        from representations: [(data: Data, fileExtension: String)]
    ) -> ImageFileListMaterializationResult {
        guard !representations.isEmpty else { return .noDecodableImagePayload }

        let maxClipboardImageSize = 10 * 1024 * 1024  // 10 MB
        var fileURLs: [URL] = []
        for representation in representations {
            guard representation.data.count <= maxClipboardImageSize else {
#if DEBUG
                cmuxDebugLog("terminal.paste.image.rejected reason=tooLarge bytes=\(representation.data.count)")
#endif
                cleanupTransferredTemporaryImageFiles(fileURLs)
                return .rejectedImagePayload
            }

            let fileURL = temporaryImageFileURL(fileExtension: representation.fileExtension)

            do {
                try representation.data.write(to: fileURL)
            } catch {
#if DEBUG
                cmuxDebugLog("terminal.paste.image.writeFailed error=\(error.localizedDescription)")
#endif
                try? FileManager.default.removeItem(at: fileURL)
                cleanupTransferredTemporaryImageFiles(fileURLs)
                return .rejectedImagePayload
            }

            registerOwnedTemporaryImageFile(fileURL)
            fileURLs.append(fileURL)
        }

        return .saved(fileURLs)
    }

    private static func temporaryImageFileURL(fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "\(temporaryImageFilenamePrefix)\(timestamp)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// Attempts to materialize a decodable pasteboard image into a temporary file.
    /// `rejectedImagePayload` means a real image was found but could not be used,
    /// so callers should not fall back to auxiliary plain text or URLs.
    static func materializeImageFileURLIfNeeded(
        from pasteboard: NSPasteboard = .general
    ) -> ImageFileMaterializationResult {
        let representations = Array(imageRepresentations(in: pasteboard).prefix(1))
        switch materializeImageFileURLs(from: representations) {
        case .saved(let fileURLs):
            guard let fileURL = fileURLs.first else { return .noDecodableImagePayload }
            return .saved(fileURL)
        case .noDecodableImagePayload:
            return .noDecodableImagePayload
        case .rejectedImagePayload:
            return .rejectedImagePayload
        }
    }

    static func materializeImageFileURLsIfNeeded(
        from pasteboard: NSPasteboard = .general
    ) -> ImageFileListMaterializationResult {
        materializeImageFileURLs(from: imageRepresentations(in: pasteboard))
    }

    static func saveImageFileURLsIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> [URL] {
        if !assumeNoText && stringContents(from: pasteboard) != nil { return [] }

        guard case .saved(let fileURLs) = materializeImageFileURLsIfNeeded(from: pasteboard) else {
            return []
        }
        return fileURLs
    }

    /// When the clipboard contains only image data (or rich text that resolves to
    /// an attachment-only image), saves it as a temporary image file and returns the
    /// file URL. Returns nil if the clipboard contains text or no image.
    static func saveImageFileURLIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> URL? {
        if !assumeNoText && stringContents(from: pasteboard) != nil { return nil }

        guard case .saved(let fileURL) = materializeImageFileURLIfNeeded(from: pasteboard) else {
            return nil
        }
        return fileURL
    }

    /// When the clipboard contains only image data (or rich text that resolves to
    /// an attachment-only image), saves it as a temporary image file and returns the
    /// shell-escaped file path. Returns nil if the clipboard contains text or no image.
    static func saveClipboardImageIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> String? {
        saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: assumeNoText)
            .map { escapeForShell($0.path) }
    }

    /// Writes raw image bytes forwarded from a remote client (e.g. an image
    /// pasted on the paired iOS app) to a temporary file and returns its
    /// shell-escaped path, ready to inject as terminal input exactly the way
    /// ``saveClipboardImageIfNeeded(from:assumeNoText:)`` does for a local paste.
    ///
    /// Returns `nil` when the payload is empty, exceeds the 10 MB clipboard-image
    /// cap, or cannot be written. The temp file is registered as owned so the
    /// usual cleanup paths reclaim it.
    static func saveImageData(_ data: Data, fileExtension: String) -> String? {
        // Mirrors the cap in materializeImageFileURLs(from:).
        let maxClipboardImageSize = 10 * 1024 * 1024  // 10 MB
        guard !data.isEmpty, data.count <= maxClipboardImageSize else { return nil }

        let fileURL = temporaryImageFileURL(fileExtension: sanitizedImageFileExtension(fileExtension))
        do {
            try data.write(to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        registerOwnedTemporaryImageFile(fileURL)
        return escapeForShell(fileURL.path)
    }

    /// Constrains a client-supplied image extension to a known-good lowercase
    /// token, defaulting to `png`, so the temp filename can never carry path
    /// separators or other hostile characters.
    private static func sanitizedImageFileExtension(_ raw: String) -> String {
        let token = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        return allowed.contains(token) ? token : "png"
    }

    static func cleanupTransferredTemporaryImageFiles(_ fileURLs: [URL]) {
        for fileURL in fileURLs {
            let normalizedURL = fileURL.standardizedFileURL
            guard normalizedURL.isFileURL,
                  consumeOwnedTemporaryImageFile(normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: normalizedURL)
        }
    }

    static func cleanupAllOwnedTemporaryImageFiles() {
        temporaryImageOwnershipLock.lock()
        let paths = ownedTemporaryImagePaths
        ownedTemporaryImagePaths.removeAll()
        temporaryImageOwnershipLock.unlock()

        for path in paths {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    static func isOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let isOwned = ownedTemporaryImagePaths.contains(normalizedPath)
        temporaryImageOwnershipLock.unlock()
        return isOwned
    }

    private static func registerOwnedTemporaryImageFile(_ fileURL: URL) {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        ownedTemporaryImagePaths.insert(normalizedPath)
        temporaryImageOwnershipLock.unlock()
    }

    private static func consumeOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let didOwnFile = ownedTemporaryImagePaths.remove(normalizedPath) != nil
        temporaryImageOwnershipLock.unlock()
        return didOwnFile
    }

#if DEBUG
    static func debugRegisterOwnedTemporaryImageFile(_ fileURL: URL) {
        registerOwnedTemporaryImageFile(fileURL)
    }
#endif
}

#if DEBUG
func cmuxPasteboardStringContentsForTesting(_ pasteboard: NSPasteboard) -> String? {
    GhosttyPasteboardHelper.stringContents(from: pasteboard)
}

func cmuxPasteboardImageFileURLForTesting(_ pasteboard: NSPasteboard) -> URL? {
    GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard)
}

func cmuxPasteboardImagePathForTesting(_ pasteboard: NSPasteboard) -> String? {
    GhosttyPasteboardHelper.saveClipboardImageIfNeeded(from: pasteboard)
}

func cmuxResolveQuicklookPathForTesting(
    _ rawText: String,
    cwd: String,
    existingPaths: Set<String>
) -> String? {
    cmuxResolveQuicklookPath(
        rawText,
        cwd: cwd,
        fileExists: { path in
            existingPaths.contains((path as NSString).standardizingPath)
        }
    )
}

func cmuxTrimTerminalPathTrailingPunctuationForTesting(_ token: String) -> String {
    cmuxTrimTerminalPathTrailingPunctuation(token)
}

func cmuxResolveTerminalOpenURLFilePathForTesting(
    _ rawText: String,
    cwd: String?,
    existingPaths: Set<String>
) -> String? {
    cmuxResolveTerminalOpenURLFilePath(
        rawText,
        cwd: cwd,
        fileExists: { path in
            existingPaths.contains((path as NSString).standardizingPath)
        }
    )
}
#endif

func cmuxResolveQuicklookPath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var seenPaths: Set<String> = []
    for token in cmuxQuicklookPathCandidates(from: trimmed) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { continue }

        let expandedToken = (normalizedToken as NSString).expandingTildeInPath
        let candidatePath: String
        if expandedToken.hasPrefix("/") {
            candidatePath = expandedToken
        } else {
            guard let cwd, !cwd.isEmpty else { continue }
            candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
        }

        let standardizedPath = (candidatePath as NSString).standardizingPath
        guard seenPaths.insert(standardizedPath).inserted else { continue }
        if fileExists(standardizedPath) {
            return standardizedPath
        }
    }

    return nil
}

private func cmuxQuicklookPathCandidates(from rawText: String) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        func appendUnique(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }

        appendUnique(trimmed)
        let punctuationTrimmed = cmuxTrimTerminalPathTrailingPunctuation(trimmed)
        if punctuationTrimmed != trimmed {
            appendUnique(punctuationTrimmed)
        }
    }

    append(rawText)

    let unescaped = cmuxUnescapeShellToken(rawText)
    if unescaped != rawText {
        append(unescaped)
    }

    if let unquoted = cmuxUnquoteShellToken(rawText) {
        append(unquoted)
        let unescapedUnquoted = cmuxUnescapeShellToken(unquoted)
        if unescapedUnquoted != unquoted {
            append(unescapedUnquoted)
        }
    }

    return candidates
}

private let cmuxTerminalPathSentencePunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?"
]

private let cmuxTerminalPathTrailingQuotes: Set<Character> = [
    "\"", "'", "”", "’", "»"
]

private let cmuxTerminalPathClosingPairs: [Character: Character] = [
    ")": "(",
    "]": "[",
    "}": "{",
    ">": "<"
]

/// Mirror smart-link terminals by trimming only the trailing punctuation run
/// that is clearly outside the path itself.
private func cmuxTrimTerminalPathTrailingPunctuation(_ token: String) -> String {
    let characters = Array(token)
    guard !characters.isEmpty else { return token }

    var end = characters.count
    while end > 0 {
        let trailing = characters[end - 1]
        if cmuxTerminalPathSentencePunctuation.contains(trailing) ||
            cmuxTerminalPathTrailingQuotes.contains(trailing) {
            end -= 1
            continue
        }

        if let opener = cmuxTerminalPathClosingPairs[trailing],
           !cmuxHasUnmatchedOpeningPathDelimiter(
               in: characters[..<(end - 1)],
               opener: opener,
               closer: trailing
           ) {
            end -= 1
            continue
        }

        break
    }

    guard end < characters.count else { return token }
    return String(characters[..<end])
}

private func cmuxHasUnmatchedOpeningPathDelimiter(
    in characters: ArraySlice<Character>,
    opener: Character,
    closer: Character
) -> Bool {
    var balance = 0
    for character in characters {
        if character == opener {
            balance += 1
        } else if character == closer, balance > 0 {
            balance -= 1
        }
    }
    return balance > 0
}

private func cmuxUnquoteShellToken(_ token: String) -> String? {
    guard token.count >= 2,
          let first = token.first,
          let last = token.last,
          first == last,
          first == "'" || first == "\"" else {
        return nil
    }
    return String(token.dropFirst().dropLast())
}

private func cmuxUnescapeShellToken(_ token: String) -> String {
    var output = String.UnicodeScalarView()
    output.reserveCapacity(token.unicodeScalars.count)
    var escaping = false

    for scalar in token.unicodeScalars {
        if escaping {
            output.append(scalar)
            escaping = false
            continue
        }

        if scalar == "\\" {
            escaping = true
            continue
        }

        output.append(scalar)
    }

    if escaping {
        output.append(UnicodeScalar(0x5C)!)
    }

    return String(output)
}

func cmuxVisibleTerminalLines(from text: String, rows: Int) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count > rows {
        return Array(lines.suffix(rows))
    }
    return lines
}

private func cmuxShellEscapedTokenContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }

    var index = 0
    while index < characters.count {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        let start = index

        while index < characters.count {
            let character = characters[index]
            guard character.isWhitespace else {
                index += 1
                continue
            }

            var backslashCount = 0
            var lookbehind = index - 1
            while lookbehind >= start, characters[lookbehind] == "\\" {
                backslashCount += 1
                lookbehind -= 1
            }

            if backslashCount % 2 == 1 {
                index += 1
                continue
            }

            break
        }

        if start < index, column >= start, column < index {
            return String(characters[start..<index])
        }
    }

    return nil
}

private func cmuxIsHardPathDelimiter(
    in characters: [Character],
    at index: Int
) -> Bool {
    let character = characters[index]
    if character == "\t" || character == "\n" || character == "\r" {
        return true
    }

    guard character.isWhitespace else { return false }
    let previousIsWhitespace = index > 0 && characters[index - 1].isWhitespace
    let nextIsWhitespace = (index + 1) < characters.count && characters[index + 1].isWhitespace
    return previousIsWhitespace || nextIsWhitespace
}

private func cmuxRawPathSegmentContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
    guard !cmuxIsHardPathDelimiter(in: characters, at: column) else { return nil }

    var start = column
    while start > 0, !cmuxIsHardPathDelimiter(in: characters, at: start - 1) {
        start -= 1
    }

    var end = column
    while (end + 1) < characters.count, !cmuxIsHardPathDelimiter(in: characters, at: end + 1) {
        end += 1
    }

    let candidate = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? nil : candidate
}

private func cmuxPathCandidatesContainingColumn(
    in line: String,
    column: Int
) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    append(cmuxRawPathSegmentContainingColumn(in: line, column: column))
    append(cmuxShellEscapedTokenContainingColumn(in: line, column: column))

    return candidates
}

func cmuxResolveVisibleLinePath(
    _ line: String,
    column: Int,
    cwd: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> (rawToken: String, path: String)? {
    for rawToken in cmuxPathCandidatesContainingColumn(in: line, column: column) {
        if let resolvedPath = cmuxResolveQuicklookPath(rawToken, cwd: cwd, fileExists: fileExists) {
            return (rawToken, resolvedPath)
        }
    }
    return nil
}

func cmuxResolveTerminalOpenURLFilePath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard URL(string: trimmed)?.scheme == nil else { return nil }
    return cmuxResolveQuicklookPath(trimmed, cwd: cwd, fileExists: fileExists)
}

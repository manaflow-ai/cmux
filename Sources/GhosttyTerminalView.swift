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

@_silgen_name("ghostty_surface_clear_selection")
private func ghostty_surface_clear_selection_compat(_ surface: ghostty_surface_t) -> Bool

enum GhosttyStartupAppearancePreviewProfile: String, CaseIterable, Identifiable {
    case realUserConfig
    case freshInstall
    case userThemePair
    case userSingleTheme
    case userExplicitColors

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.title",
                defaultValue: "Real User Config"
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.title",
                defaultValue: "Fresh Install"
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.title",
                defaultValue: "User Light/Dark Theme"
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.title",
                defaultValue: "User Single Theme"
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.title",
                defaultValue: "User Explicit Colors"
            )
        }
    }

    var detail: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.detail",
                defaultValue: "Loads your actual Ghostty and cmux config files."
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.detail",
                defaultValue: "No user theme or terminal colors, so cmux applies its managed default colors."
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.detail",
                defaultValue: "Simulates a user with an explicit light/dark Ghostty theme."
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.detail",
                defaultValue: "Simulates a user with one Ghostty theme applied in both appearances."
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.detail",
                defaultValue: "Simulates a user with direct terminal color settings and no theme."
            )
        }
    }

    var loadsRealUserConfig: Bool {
        self == .realUserConfig
    }

    func previewConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference()
    ) -> String? {
        switch self {
        case .realUserConfig:
            return nil
        case .freshInstall:
            return GhosttyConfig.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme
            )
        case .userThemePair:
            return "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        case .userSingleTheme:
            return "theme = Catppuccin Mocha"
        case .userExplicitColors:
            return """
            background = #101820
            foreground = #F4F7F7
            cursor-color = #FEE715
            cursor-text = #101820
            selection-background = #28536B
            selection-foreground = #F4F7F7
            palette = 0=#101820
            palette = 1=#C14953
            palette = 2=#47A025
            palette = 3=#D9A441
            palette = 4=#2E86AB
            palette = 5=#9B5DE5
            palette = 6=#00A6A6
            palette = 7=#D6D6D6
            palette = 8=#5C6672
            palette = 9=#FF6B6B
            palette = 10=#7BD88F
            palette = 11=#FFD166
            palette = 12=#54C6EB
            palette = 13=#C77DFF
            palette = 14=#4ECDC4
            palette = 15=#FFFFFF
            """
        }
    }
}

enum GhosttyStartupAppearancePreviewState {
    static var profile: GhosttyStartupAppearancePreviewProfile = .realUserConfig
}

#if os(macOS)
func cmuxShouldApplyWindowGlass(
    sidebarBlendMode: String,
    bgGlassEnabled: Bool,
    glassEffectAvailable _: Bool
) -> Bool {
    // Native NSGlassEffectView vs NSVisualEffectView fallback is chosen inside
    // WindowGlassEffect.apply. User settings alone decide whether glass is on.
    sidebarBlendMode == "behindWindow" && bgGlassEnabled
}

func cmuxShouldUseTransparentBackgroundWindow() -> Bool {
    let defaults = UserDefaults.standard
    let sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    let bgGlassEnabled = defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false
    return cmuxShouldApplyWindowGlass(
        sidebarBlendMode: sidebarBlendMode,
        bgGlassEnabled: bgGlassEnabled,
        glassEffectAvailable: WindowGlassEffect.isAvailable
    )
}

func cmuxShouldUseClearWindowBackground(for opacity: Double, usesGhosttyGlassStyle: Bool = false) -> Bool {
    cmuxShouldUseTransparentBackgroundWindow() || usesGhosttyGlassStyle || opacity < 0.999
}

@_silgen_name("CGSDefaultConnectionForThread")
private func cmuxCGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func cmuxCGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: UInt,
    _ radius: Int32
) -> Int32

func cmuxResetCompositorBackgroundBlur(on window: NSWindow) {
    _ = cmuxCGSSetWindowBackgroundBlurRadius(
        cmuxCGSDefaultConnectionForThread(),
        UInt(window.windowNumber),
        0
    )
}

func cmuxTransparentWindowBaseColor() -> NSColor {
    // A tiny non-zero alpha matches Ghostty's window compositing behavior on macOS and
    // avoids visual artifacts that can happen with a fully clear window background.
    NSColor.white.withAlphaComponent(0.001)
}

// `flagsChanged` is used for both modifier presses and releases on macOS.
// Returning the wrong edge leaves Ghostty with a phantom held modifier until
// a later focus loss flushes release events into the PTY.
func cmuxGhosttyModifierActionForFlagsChanged(
    keyCode: UInt16,
    modifierFlagsRawValue: UInt
) -> ghostty_input_action_e? {
    let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    let modifierActive: Bool
    switch keyCode {
    case 0x39:
        modifierActive = flags.contains(.capsLock)
    case 0x38, 0x3C:
        modifierActive = flags.contains(.shift)
    case 0x3B, 0x3E:
        modifierActive = flags.contains(.control)
    case 0x3A, 0x3D:
        modifierActive = flags.contains(.option)
    case 0x37, 0x36:
        modifierActive = flags.contains(.command)
    default:
        return nil
    }

    guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

    let sidePressed: Bool
    switch keyCode {
    case 0x38:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
    case 0x3C:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
    case 0x3B:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
    case 0x3E:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
    case 0x3A:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELALTKEYMASK) != 0
    case 0x3D:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERALTKEYMASK) != 0
    case 0x37:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
    case 0x36:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
    default:
        sidePressed = true
    }

    return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
}
#endif

private func cmuxRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyApp.runtimeReadClipboardCallback(userdata, location, state)
}

#if DEBUG
private func cmuxChildExitProbePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
          let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
          !path.isEmpty else {
        return nil
    }
    return path
}

private func cmuxLoadChildExitProbe(at path: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return object
}

private func cmuxWriteChildExitProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
    guard let path = cmuxChildExitProbePath() else { return }
    var payload = cmuxLoadChildExitProbe(at: path)
    for (key, by) in increments {
        let current = Int(payload[key] ?? "") ?? 0
        payload[key] = String(current + by)
    }
    for (key, value) in updates {
        payload[key] = value
    }
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

private func cmuxScalarHex(_ value: String?) -> String {
    guard let value else { return "" }
    return value.unicodeScalars
        .map { String(format: "%04X", $0.value) }
        .joined(separator: ",")
}
#endif

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

private func cmuxResolveQuicklookPath(
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

private func cmuxVisibleTerminalLines(from text: String, rows: Int) -> [String] {
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

private func cmuxResolveVisibleLinePath(
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

private func cmuxResolveTerminalOpenURLFilePath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard URL(string: trimmed)?.scheme == nil else { return nil }
    return cmuxResolveQuicklookPath(trimmed, cwd: cwd, fileExists: fileExists)
}

enum TerminalOpenURLTarget: Equatable {
    case embeddedBrowser(URL)
    case external(URL)

    var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    #if DEBUG
    cmuxDebugLog("link.resolve input=\(trimmed)")
    #endif
    guard !trimmed.isEmpty else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (empty)")
        #endif
        return nil
    }

    if NSString(string: trimmed).isAbsolutePath {
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(absolutePath) url=\(trimmed)")
        #endif
        return .external(URL(fileURLWithPath: trimmed))
    }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            guard BrowserInsecureHTTPSettings.normalizeHost(parsed.host ?? "") != nil else {
                #if DEBUG
                cmuxDebugLog("link.resolve result=external(invalidHost) url=\(parsed)")
                #endif
                return .external(parsed)
            }
            #if DEBUG
            cmuxDebugLog("link.resolve result=embeddedBrowser url=\(parsed)")
            #endif
            return .embeddedBrowser(parsed)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
        #endif
        return .external(parsed)
    }

    if let webURL = resolveBrowserNavigableURL(trimmed) {
        guard BrowserInsecureHTTPSettings.normalizeHost(webURL.host ?? "") != nil else {
            #if DEBUG
            cmuxDebugLog("link.resolve result=external(bareHost-invalidHost) url=\(webURL)")
            #endif
            return .external(webURL)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=embeddedBrowser(bareHost) url=\(webURL)")
        #endif
        return .embeddedBrowser(webURL)
    }

    guard let fallback = URL(string: trimmed) else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (unparseable)")
        #endif
        return nil
    }
    #if DEBUG
    cmuxDebugLog("link.resolve result=external(fallback) url=\(fallback)")
    #endif
    return .external(fallback)
}

private var terminalKeyboardCopyModeIndicatorText: String {
    String(localized: "ghostty.copy-mode.indicator", defaultValue: "vim")
}

private var terminalKeyTableIndicatorDefaultText: String {
    String(localized: "ghostty.key-table.indicator", defaultValue: "key table")
}

private var terminalKeyTableIndicatorAccessibilityLabel: String {
    String(localized: "ghostty.key-table.icon.accessibility", defaultValue: "Key table")
}

private func terminalKeyTableIndicatorText(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "", "set":
        return terminalKeyTableIndicatorDefaultText
    case "vi", "vim":
        return terminalKeyboardCopyModeIndicatorText
    default:
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? terminalKeyTableIndicatorDefaultText : normalized
    }
}

private func terminalKeyboardCopyModeModifiers(
    _ modifierFlags: NSEvent.ModifierFlags
) -> TerminalKeyboardCopyModeModifiers {
    let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: TerminalKeyboardCopyModeModifiers = []
    if normalized.contains(.command) {
        modifiers.insert(.command)
    }
    if normalized.contains(.shift) {
        modifiers.insert(.shift)
    }
    if normalized.contains(.control) {
        modifiers.insert(.control)
    }
    if normalized.contains(.numericPad) {
        modifiers.insert(.numericPad)
    }
    if normalized.contains(.function) {
        modifiers.insert(.function)
    }
    if normalized.contains(.capsLock) {
        modifiers.insert(.capsLock)
    }
    return modifiers
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeShouldBypassForShortcut(
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags)
    )
}

func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeAction? {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
        hasSelection: hasSelection,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeResolution {
    CmuxTerminalCopyMode.terminalKeyboardCopyModeResolve(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: terminalKeyboardCopyModeModifiers(modifierFlags),
        hasSelection: hasSelection,
        state: &state,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

private final class GhosttySurfaceCallbackContext {
    weak var surfaceView: GhosttyNSView?
    weak var terminalSurface: TerminalSurface?
    let surfaceId: UUID

    init(surfaceView: GhosttyNSView, terminalSurface: TerminalSurface) {
        self.surfaceView = surfaceView
        self.terminalSurface = terminalSurface
        self.surfaceId = terminalSurface.id
    }

    var tabId: UUID? {
        terminalSurface?.tabId ?? surfaceView?.tabId
    }

    var runtimeSurface: ghostty_surface_t? {
        terminalSurface?.surface ?? surfaceView?.terminalSurface?.surface
    }
}

// The native pointer has been removed from all main-thread owner state before
// this request is created; this wrapper only transports the one-shot free.
private struct TerminalSurfaceRuntimeTeardownRequest: @unchecked Sendable {
    let id: UUID
    let workspaceId: UUID
    let reason: String
    let surface: ghostty_surface_t
    let callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    let freeSurface: @Sendable (ghostty_surface_t) -> Void
#if DEBUG
    let surfaceToken: String
    let workspaceToken: String
#endif

    init(
        id: UUID,
        workspaceId: UUID,
        reason: String,
        surface: ghostty_surface_t,
        callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.reason = reason
        self.surface = surface
        self.callbackContext = callbackContext
        self.freeSurface = freeSurface
#if DEBUG
        self.surfaceToken = String(id.uuidString.prefix(5))
        self.workspaceToken = String(workspaceId.uuidString.prefix(5))
#endif
    }
}

private actor TerminalSurfaceRuntimeTeardownCoordinator {
    static let shared = TerminalSurfaceRuntimeTeardownCoordinator()

    private let timeout: Duration = .seconds(5)
    private var pendingReasonsById: [UUID: String] = [:]
    private var queuedRequests: [TerminalSurfaceRuntimeTeardownRequest] = []
    private var isWorkerRunning = false

    func enqueue(_ request: TerminalSurfaceRuntimeTeardownRequest) {
        pendingReasonsById[request.id] = request.reason
        queuedRequests.append(request)
        if !isWorkerRunning {
            isWorkerRunning = true
            Task.detached(priority: .utility) {
                while let request = await self.nextRequestForWorker() {
                    Task {
                        await self.observeTimeout(id: request.id)
                    }
                    await Self.free(request)
                    await self.complete(id: request.id)
                }
            }
        }
    }

    private func nextRequestForWorker() -> TerminalSurfaceRuntimeTeardownRequest? {
        guard !queuedRequests.isEmpty else {
            isWorkerRunning = false
            return nil
        }
        return queuedRequests.removeFirst()
    }

    private nonisolated static func free(_ request: TerminalSurfaceRuntimeTeardownRequest) async {
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.begin surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
        request.freeSurface(request.surface)
        if let callbackContext = request.callbackContext {
            await MainActor.run {
                callbackContext.release()
            }
        }
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.end surface=\(request.surfaceToken) " +
            "workspace=\(request.workspaceToken) reason=\(request.reason)"
        )
#endif
    }

    private func complete(id: UUID) {
        pendingReasonsById.removeValue(forKey: id)
    }

    private func observeTimeout(id: UUID) async {
        do {
            // Genuine teardown deadline: report a stuck native free without blocking close.
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        guard let reason = pendingReasonsById[id] else { return }
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.nativeFree.timeout surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason)"
        )
#endif
    }
}

private func enqueueTerminalSurfaceRuntimeTeardown(
    id: UUID,
    workspaceId: UUID,
    reason: String,
    surface: ghostty_surface_t,
    callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?,
    freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
) {
    let request = TerminalSurfaceRuntimeTeardownRequest(
        id: id,
        workspaceId: workspaceId,
        reason: reason,
        surface: surface,
        callbackContext: callbackContext,
        freeSurface: freeSurface
    )
    Task {
        await TerminalSurfaceRuntimeTeardownCoordinator.shared.enqueue(request)
    }
}

private func enqueueTerminalSurfaceRuntimeTeardown(
    id: UUID,
    workspaceId: UUID,
    reason: String,
    surface: ghostty_surface_t,
    callbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
) {
    enqueueTerminalSurfaceRuntimeTeardown(
        id: id,
        workspaceId: workspaceId,
        reason: reason,
        surface: surface,
        callbackContext: callbackContext,
        freeSurface: { surface in ghostty_surface_free(surface) }
    )
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    enum ScrollbarVisibility: String {
        case system
        case never
    }

    static let shared = GhosttyApp()
    private static let releaseBundleIdentifier = "com.cmuxterm.app"
    private static let fallbackAppearanceConfig = GhosttyConfig()
    private static let initializationLogger = Logger(
        subsystem: releaseBundleIdentifier,
        category: "ghostty.initialization"
    )
    // SAFETY: Ghostty C callbacks can run while GhosttyApp.shared is still initializing.
    // cmux owns one process-lifetime GhosttyApp, so the registry avoids singleton re-entry
    // without adding a teardown path for a ghostty_app_t that is never freed/recreated.
    private static let appRegistryLock = NSLock()
    private static var appRegistry: [UInt: GhosttyApp] = [:]
    private static var initializingRuntimeApp: GhosttyApp?
    private static let backgroundLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// Coalesce wakeup → tick dispatches.  The I/O thread may fire wakeup_cb
    /// thousands of times per second during bulk output.  We only need one
    /// pending tick on the main queue at any time.
    private var _tickScheduled = false
    private let _tickLock = NSLock()
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    private(set) var defaultBackgroundBlur: GhosttyBackgroundBlur = .disabled
    private(set) var defaultForegroundColor: NSColor = GhosttyApp.fallbackAppearanceConfig.foregroundColor
    private(set) var defaultCursorColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorColor
    private(set) var defaultCursorTextColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorTextColor
    private(set) var defaultSelectionBackground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionBackground
    private(set) var defaultSelectionForeground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionForeground
    private(set) var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference = .dark
    private var appliedGhosttyRuntimeColorScheme: ghostty_color_scheme_e?
    private var runtimeColorSchemeSynchronizationDepth = 0
    private var reloadConfigurationDepth = 0
    private(set) var usesHostLayerBackground = false
    private(set) var userGhosttyShellIntegrationMode: String = "detect"

    static func retainTickNotifications() -> () -> Void {
        GhosttyTickNotificationDemand.retain()
    }

    private static func resolveBackgroundLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicitPath = environment["CMUX_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["CMUX_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/cmux-bg.log")
    }

#if DEBUG
    private static func debugDescription(
        for preparedContent: TerminalImageTransferPreparedContent
    ) -> String {
        switch preparedContent {
        case .insertText(let text):
            return "insertText(length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0))"
        case .fileURLs(let fileURLs):
            return "fileURLs(count:\(fileURLs.count))"
        case .reject:
            return "reject"
        }
    }
#endif

    fileprivate static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let callbackContext = Self.callbackContext(from: userdata),
              let requestSurface = callbackContext.runtimeSurface else { return false }

        DispatchQueue.main.async {
            func completeClipboardRequest(with text: String) {
                let finish = {
                    guard callbackContext.runtimeSurface == requestSurface else { return }
                    text.withCString { ptr in
                        ghostty_surface_complete_clipboard_request(requestSurface, ptr, state, false)
                    }
                    callbackContext.terminalSurface?.noteClipboardReadCompleted()
                }
                if Thread.isMainThread {
                    finish()
                } else {
                    DispatchQueue.main.async(execute: finish)
                }
            }

            guard let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }

            let preparedContent = TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .paste
            )

#if DEBUG
            cmuxDebugLog(
                "terminal.clipboard.read surface=\(callbackContext.surfaceId.uuidString.prefix(5)) " +
                "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")) " +
                "prepared=\(Self.debugDescription(for: preparedContent))"
            )
#endif

            switch preparedContent {
            case .reject:
                completeClipboardRequest(with: "")
            case .insertText(let text):
                completeClipboardRequest(with: text)
            case .fileURLs(let fileURLs):
                let operation = TerminalImageTransferOperation()
                MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.hostedView.beginImageTransferIndicator(
                        for: operation,
                        onCancel: {
                            completeClipboardRequest(with: "")
                        }
                    )
                }

                let target = MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.resolvedImageTransferTarget() ?? .local
                }
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                TerminalImageTransferPlanner.execute(
                    plan: plan,
                    operation: operation,
                    uploadWorkspaceRemote: { fileURLs, operation, finish in
                        guard let workspace = MainActor.assumeIsolated({
                            callbackContext.terminalSurface?.owningWorkspace()
                        }) else {
                            finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            return
                        }
                        workspace.uploadDroppedFilesForRemoteTerminal(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    uploadDetectedSSH: { session, fileURLs, operation, finish in
                        session.uploadDroppedFiles(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    insertText: { text in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        completeClipboardRequest(with: text)
                    },
                    onFailure: { _ in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        NSSound.beep()
#if DEBUG
                        cmuxDebugLog("terminal.remotePasteUpload.failed surface=\(callbackContext.surfaceId.uuidString.prefix(5))")
#endif
                        completeClipboardRequest(with: "")
                    }
                )
            }
        }

        return true
    }

    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"] != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxDebugBG")
    }()
    private let backgroundLogURL = GhosttyApp.resolveBackgroundLogURL()
    private let backgroundLogStartUptime = ProcessInfo.processInfo.systemUptime
    private let backgroundLogLock = NSLock()
    private var backgroundLogSequence: UInt64 = 0
    private var appObservers: [NSObjectProtocol] = []
    private var bellAudioSound: NSSound?
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?
    private lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        GhosttyDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.backgroundLogEnabled else { return }
            self.logBackground(message)
        })

    // Scroll lag tracking
    private(set) var isScrolling = false
    private var scrollLagSampleCount = 0
    private var scrollLagTotalMs: Double = 0
    private var scrollLagMaxMs: Double = 0
    private let scrollLagThresholdMs: Double = 40
    private let scrollLagMinimumSamples = 8
    private let scrollLagMinimumAverageMs: Double = 12
    private let scrollLagReportCooldownSeconds: TimeInterval = 300
    private var lastScrollLagReportUptime: TimeInterval?
    private var scrollEndTimer: DispatchWorkItem?

    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        }
    }

    private func endScrollSession() {
        guard isScrolling else { return }
        isScrolling = false

        // Report accumulated lag stats if any exceeded threshold
        if scrollLagSampleCount > 0 {
            let avgLag = scrollLagTotalMs / Double(scrollLagSampleCount)
            let maxLag = scrollLagMaxMs
            let samples = scrollLagSampleCount
            let threshold = scrollLagThresholdMs
            let nowUptime = ProcessInfo.processInfo.systemUptime
            if Self.shouldCaptureScrollLagEvent(
                samples: samples,
                averageMs: avgLag,
                maxMs: maxLag,
                thresholdMs: threshold,
                minimumSamples: scrollLagMinimumSamples,
                minimumAverageMs: scrollLagMinimumAverageMs,
                nowUptime: nowUptime,
                lastReportedUptime: lastScrollLagReportUptime,
                cooldown: scrollLagReportCooldownSeconds
            ) {
                if TelemetrySettings.enabledForCurrentLaunch {
                    SentrySDK.capture(message: "Scroll lag detected") { scope in
                        scope.setLevel(.warning)
                        scope.setContext(value: [
                            "samples": samples,
                            "avg_ms": String(format: "%.2f", avgLag),
                            "max_ms": String(format: "%.2f", maxLag),
                            "threshold_ms": threshold
                        ], key: "scroll_lag")
                    }
                }
                lastScrollLagReportUptime = nowUptime
            }
            // Reset stats
            scrollLagSampleCount = 0
            scrollLagTotalMs = 0
            scrollLagMaxMs = 0
        }
    }

    private init() {
        initializeGhostty()
    }

    #if DEBUG
    private static let initLogPath = "/tmp/cmux-ghostty-init.log"

    private static func initLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: initLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: initLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func dumpConfigDiagnostics(_ config: ghostty_config_t, label: String) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else {
            initLog("ghostty diagnostics (\(label)): none")
            return
        }
        initLog("ghostty diagnostics (\(label)): count=\(count)")
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            initLog("  [\(i)] \(msg)")
        }
    }
    #endif

    private static func reportInitializationFailure(
        _ message: String,
        data: [String: Any] = [:]
    ) {
        if data.isEmpty {
            initializationLogger.error("\(message, privacy: .public)")
        } else {
            initializationLogger.error("\(message, privacy: .public) \(String(describing: data), privacy: .public)")
        }
        sentryCaptureError(
            message,
            category: "terminal",
            data: data,
            contextKey: "ghostty.initialization"
        )
    }

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            #if DEBUG
            cmuxDebugLog("ghostty.initialize.failed result=\(result)")
            #endif
            Self.reportInitializationFailure(
                "ghostty.initialize.failed",
                data: ["result": Int(result)]
            )
            return
        }

        // Load config
        guard let primaryConfig = ghostty_config_new() else {
            #if DEBUG
            cmuxDebugLog("ghostty.initialize.config.failed")
            #endif
            Self.reportInitializationFailure("ghostty.initialize.config.failed")
            return
        }

        let initialColorScheme = GhosttyConfig.currentColorSchemePreference()

        // Load default config (includes user config). If this fails hard (e.g. due to
        // invalid user config), ghostty_app_new may return nil; we fall back below.
        let primaryRenderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            primaryConfig,
            preferredColorScheme: initialColorScheme
        )
        updateDefaultBackground(
            from: primaryConfig,
            source: "initialize.primaryConfig",
            forceNotify: primaryRenderingModeChanged
        )
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "initialize.primaryConfig",
            preferredColorScheme: initialColorScheme,
            baselineConfig: primaryConfig,
            forceNotify: primaryRenderingModeChanged
        )

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            GhosttyApp.runtimeApp(from: userdata)?.scheduleTick()
        }
        runtimeConfig.action_cb = { app, target, action in
            guard let runtimeApp = GhosttyApp.runtimeAppForActionCallback(app) else { return false }
            return runtimeApp.handleAction(target: target, action: action)
        }
        // Some GhosttyKit builds import this callback as returning `Void` in Swift even
        // though the C ABI returns `bool`. Store the C-compatible shim explicitly so the
        // project compiles against both importer variants.
        runtimeConfig.read_clipboard_cb = unsafeBitCast(
            cmuxRuntimeReadClipboardCallback as @convention(c) (
                UnsafeMutableRawPointer?,
                ghostty_clipboard_e,
                UnsafeMutableRawPointer?
            ) -> Bool,
            to: ghostty_runtime_read_clipboard_cb.self
        )
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata),
                  let surface = callbackContext.runtimeSurface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
            DispatchQueue.main.async {
                callbackContext.terminalSurface?.noteClipboardReadCompleted()
            }
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId

#if DEBUG
            cmuxWriteChildExitProbe(
                [
                    "probeCloseSurfaceNeedsConfirm": needsConfirmClose ? "1" : "0",
                    "probeCloseSurfaceTabId": callbackTabId?.uuidString ?? "",
                    "probeCloseSurfaceSurfaceId": callbackSurfaceId.uuidString,
                ],
                increments: ["probeCloseSurfaceCbCount": 1]
            )
#endif

            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                guard let callbackSurface = callbackContext.terminalSurface else {
#if DEBUG
                    cmuxDebugLog(
                        "surface.closeCallback.ignore surface=\(callbackSurfaceId.uuidString.prefix(5)) reason=missingCallbackSurface"
                    )
#endif
                    return
                }
                if let registeredSurface = TerminalSurfaceRegistry.shared.surface(id: callbackSurfaceId),
                   registeredSurface !== callbackSurface {
#if DEBUG
                    cmuxDebugLog(
                        "surface.closeCallback.ignore surface=\(callbackSurfaceId.uuidString.prefix(5)) reason=staleCallbackSurface"
                    )
#endif
                    return
                }
                // Close requests must be resolved by the callback's workspace/surface IDs only.
                // If the mapping is already gone (duplicate/stale callback), ignore it.
                if let callbackTabId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    if needsConfirmClose {
                        manager.closeRuntimeSurfaceWithConfirmation(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    } else {
                        manager.closeRuntimeSurface(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    }
                }
            }
        }

        // Create app
        Self.setInitializingRuntimeApp(self)
        defer { Self.setInitializingRuntimeApp(nil) }

        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
            Self.registerRuntimeApp(self, for: created)
        } else {
            #if DEBUG
            Self.initLog("ghostty_app_new(primary) failed; attempting fallback config")
            Self.dumpConfigDiagnostics(primaryConfig, label: "primary")
            #endif

            // If the user config is invalid, prefer a minimal fallback configuration so
            // cmux still launches with working terminals.
            ghostty_config_free(primaryConfig)

            guard let fallbackConfig = ghostty_config_new() else {
                #if DEBUG
                cmuxDebugLog("ghostty.initialize.fallbackConfig.failed")
                #endif
                Self.reportInitializationFailure("ghostty.initialize.fallbackConfig.failed")
                return
            }

            loadInlineGhosttyConfig(
                "macos-background-from-layer = true",
                into: fallbackConfig,
                prefix: "cmux-renderer-bg",
                logLabel: "renderer background (fallback)"
            )
            loadInlineGhosttyConfig(
                "macos-titlebar-proxy-icon = hidden",
                into: fallbackConfig,
                prefix: "cmux-titlebar-proxy-icon",
                logLabel: "titlebar proxy icon (fallback)"
            )
            loadInlineGhosttyConfig(
                "shell-integration = none",
                into: fallbackConfig,
                prefix: "cmux-shell-integration-override",
                logLabel: "shell integration override (fallback)"
            )
            loadCmuxManagedTerminalSettingsConfig(fallbackConfig)
            loadCmuxOwnedGhosttyKeybindOverrides(fallbackConfig)
            loadNoActiveDisplayVsyncFallbackIfNeeded(fallbackConfig)
            let fallbackRenderingModeChanged = setUsesHostLayerBackground(
                true,
                source: "initialize.fallbackConfig"
            )
            ghostty_config_finalize(fallbackConfig)
            updateDefaultBackground(
                from: fallbackConfig,
                source: "initialize.fallbackConfig",
                forceNotify: fallbackRenderingModeChanged
            )
            updateDefaultBackgroundFromResolvedGhosttyConfig(
                source: "initialize.fallbackConfig",
                preferredColorScheme: initialColorScheme,
                baselineConfig: fallbackConfig,
                useOnDiskResolvedConfig: false,
                forceNotify: fallbackRenderingModeChanged
            )

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                #if DEBUG
                Self.initLog("ghostty_app_new(fallback) failed")
                Self.dumpConfigDiagnostics(fallbackConfig, label: "fallback")
                #endif
                #if DEBUG
                cmuxDebugLog("ghostty.initialize.app.failed")
                #endif
                Self.reportInitializationFailure("ghostty.initialize.app.failed")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
            Self.registerRuntimeApp(self, for: created)
        }

        // Notify observers that a usable config is available (initial load).
        synchronizeGhosttyRuntimeColorScheme(effectiveTerminalColorSchemePreference, source: "initialize")
        lastAppearanceColorScheme = initialColorScheme
        GhosttyConfig.invalidateLoadCache()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: TerminalCopyOnSelectSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadConfiguration(source: "settings.terminal.copyOnSelect")
        })

        #endif
    }

    private func loadInlineGhosttyConfig(
        _ contents: String,
        into config: ghostty_config_t,
        prefix: String,
        logLabel _: String
    ) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let syntheticPath = "/__cmux_inline__/\(prefix).conf"
        trimmed.withCString { contents in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(trimmed.lengthOfBytes(using: .utf8)),
                    path
                )
            }
        }
    }

    private func loadCmuxDefaultAppearanceConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if let url = GhosttyConfig.cmuxDefaultThemeConfigURL(preferredColorScheme: preferredColorScheme) {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            return
        }

        loadInlineGhosttyConfig(
            GhosttyConfig.cmuxDefaultThemeConfigContents(preferredColorScheme: preferredColorScheme),
            into: config,
            prefix: "cmux-default-appearance",
            logLabel: "default appearance fallback"
        )
    }

    private func loadCmuxManagedTerminalSettingsConfig(_ config: ghostty_config_t) {
        guard let contents = TerminalManagedGhosttySettings.ghosttyConfigContents() else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-managed-terminal-settings",
            logLabel: "managed terminal settings"
        )
    }

    private func loadStartupPreviewProfile(
        _ profile: GhosttyStartupAppearancePreviewProfile,
        into config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if profile == .freshInstall {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
            return
        }

        guard let contents = profile.previewConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-startup-preview",
            logLabel: "startup appearance preview"
        )
    }

    private func loadConditionalThemeOverrideIfNeeded(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        guard let contents = Self.conditionalThemeOverrideConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }

        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-conditional-theme",
            logLabel: "conditional theme override"
        )
    }

    func loadDefaultConfigFilesWithLegacyFallback(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference(),
        conditionalThemeColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) -> Bool {
        // Surface-only reloads may use a terminal-derived scheme for background
        // handling, while Ghostty split-theme pairs follow app appearance.
        let themeColorScheme = conditionalThemeColorScheme ?? preferredColorScheme

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            ghostty_config_load_default_files(config)
            loadLegacyGhosttyConfigIfNeeded(config)
            loadCmuxAppSupportGhosttyConfigIfNeeded(config)
            ghostty_config_load_recursive_files(config)
            loadConditionalThemeOverrideIfNeeded(
                config,
                preferredColorScheme: themeColorScheme
            )
            if Self.shouldApplyManagedDefaultAppearance() {
                loadCmuxDefaultAppearanceConfig(
                    config,
                    preferredColorScheme: preferredColorScheme
                )
            }
        } else {
            loadStartupPreviewProfile(
                startupPreviewProfile,
                into: config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #else
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadCmuxAppSupportGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadConditionalThemeOverrideIfNeeded(
            config,
            preferredColorScheme: themeColorScheme
        )
        if Self.shouldApplyManagedDefaultAppearance() {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif
        loadCJKFontFallbackIfNeeded(config)
        let renderingModeChanged = setUsesHostLayerBackground(
            true,
            source: "loadDefaultConfigFilesWithLegacyFallback"
        )
        // Let cmux own the window-level backdrop once, while Ghostty keeps
        // rendering text, cell backgrounds, and background images. This avoids
        // separate translucent fills for terminal and chrome surfaces.
        loadInlineGhosttyConfig(
            "macos-background-from-layer = true",
            into: config,
            prefix: "cmux-renderer-bg",
            logLabel: "renderer background"
        )
        // Hide Ghostty's native AppKit proxy icon at the source instead of
        // overriding NSWindow.representedURL on every cmux main window.
        loadInlineGhosttyConfig(
            "macos-titlebar-proxy-icon = hidden",
            into: config,
            prefix: "cmux-titlebar-proxy-icon",
            logLabel: "titlebar proxy icon"
        )
        // Save the user's preference before we force it to none.
        userGhosttyShellIntegrationMode = "detect"
        do {
            var value: UnsafePointer<Int8>?
            let key = "shell-integration"
            if ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
               let value {
                userGhosttyShellIntegrationMode = String(cString: value)
            }
        }

        // Prevent Ghostty from overriding ZDOTDIR — cmux handles shell
        // integration itself via the .zshenv bootstrap (#2594).
        loadInlineGhosttyConfig(
            "shell-integration = none",
            into: config,
            prefix: "cmux-shell-integration-override",
            logLabel: "shell integration override"
        )
        loadCmuxManagedTerminalSettingsConfig(config)
        loadCmuxOwnedGhosttyKeybindOverrides(config)
        loadNoActiveDisplayVsyncFallbackIfNeeded(config)

        ghostty_config_finalize(config)
        return renderingModeChanged
    }

    private func loadNoActiveDisplayVsyncFallbackIfNeeded(_ config: ghostty_config_t) {
        var displayCount: UInt32 = 0
        let error = CGGetActiveDisplayList(0, nil, &displayCount)
        guard error == .success, displayCount == 0 else { return }

        loadInlineGhosttyConfig(
            "window-vsync = false",
            into: config,
            prefix: "cmux-no-active-display-vsync-fallback",
            logLabel: "no active display vsync fallback"
        )
#if DEBUG
        cmuxDebugLog("ghostty.vsync.disable reason=noActiveDisplays")
#endif
    }

    private func loadCmuxOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        // cmux owns these split and close shortcuts through KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of splitting or closing outside
        // the remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            """,
            into: config,
            prefix: "cmux-owned-keybind-overrides",
            logLabel: "cmux-owned keybind overrides"
        )
    }

    /// When the user has not configured `font-codepoint-map` for CJK ranges
    /// and has not already provided an explicit multi-entry `font-family`
    /// fallback chain, Ghostty's `CTFontCollection` scoring may pick an
    /// inappropriate fallback font for Hiragana, Katakana, and CJK symbols.
    /// The scoring prioritizes monospace fonts, so decorative fonts with
    /// monospace attributes (e.g. AB_appare from Adobe CC, or LingWai) can be
    /// selected depending on what is installed. This injects a sensible
    /// default based on the system's preferred languages without overriding
    /// user-managed fallback chains or configured fonts that already cover
    /// the affected CJK ranges.
    ///
    /// See: https://github.com/manaflow-ai/cmux/pull/1017
    private func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        guard let mappings = Self.autoInjectedCJKFontMappings() else { return }

        var resolvedFonts: [String: String] = [:]
        let lines = mappings.map { range, font in
            let resolvedFont = resolvedFonts[font] ?? {
                let resolved = Self.resolvedInjectedCJKFontName(named: font)
                resolvedFonts[font] = resolved
                return resolved
            }()
            return "font-codepoint-map = \(range)=\(resolvedFont)"
        }.joined(separator: "\n")
        loadInlineGhosttyConfig(
            lines,
            into: config,
            prefix: "cmux-cjk-font-fallback",
            logLabel: "CJK font fallback"
        )
    }

    /// Unicode ranges shared by all CJK languages (Han ideographs, symbols, fullwidth forms).
    private static let sharedCJKRanges = [
        "U+3000-U+303F",  // CJK Symbols and Punctuation
        "U+4E00-U+9FFF",  // CJK Unified Ideographs
        "U+F900-U+FAFF",  // CJK Compatibility Ideographs
        "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
        "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    ]

    /// Unicode ranges specific to Japanese (kana).
    private static let japaneseRanges = [
        "U+3040-U+309F",  // Hiragana
        "U+30A0-U+30FF",  // Katakana
    ]

    /// Representative scalars used to detect whether the configured primary
    /// font already covers the ranges cmux would otherwise auto-map.
    private static let cjkCoverageSampleCharactersByRange: [String: [UniChar]] = [
        "U+3000-U+303F": [0x3001, 0x300C],
        "U+4E00-U+9FFF": [0x4E00, 0x65E5, 0x6C34],
        "U+F900-U+FAFF": [0xF900],
        "U+FF00-U+FFEF": [0xFF10, 0xFF21],
        "U+3400-U+4DBF": [0x3400],
        "U+1100-U+11FF": [0x1100, 0x1161],
        "U+3130-U+318F": [0x3131, 0x314F],
        "U+3040-U+309F": [0x3042, 0x3093],
        "U+30A0-U+30FF": [0x30A2, 0x30F3],
        "U+AC00-U+D7AF": [0xAC00, 0xD55C],
    ]

    private struct UserFontConfigSummary {
        var containsCodepointMap = false
        var effectiveFontFamilies: [String] = []

        var hasExplicitFontFamilyFallbackChain: Bool {
            effectiveFontFamilies.count > 1
        }

        mutating func applyFontCodepointMap(_ value: String) {
            if value.isEmpty {
                containsCodepointMap = false
                return
            }

            guard value.contains("=") else {
                return
            }

            containsCodepointMap = true
        }

        mutating func recordFontFamily(_ value: String) {
            if value.isEmpty {
                effectiveFontFamilies.removeAll()
                return
            }

            guard !effectiveFontFamilies.contains(value) else {
                return
            }

            effectiveFontFamilies.append(value)
        }
    }

    private struct UserAppearanceConfigSummary {
        var hasThemeDirective = false
        var hasExplicitTerminalColorDirective = false
        var lastThemeDirective: String?

        var shouldApplyDefaultAppearance: Bool {
            !hasThemeDirective && !hasExplicitTerminalColorDirective
        }

        mutating func recordDirective(key: String, value: String?) {
            switch key {
            case "theme":
                hasThemeDirective = true
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lastThemeDirective = trimmedValue.isEmpty ? nil : trimmedValue
            case "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                hasExplicitTerminalColorDirective = true
            default:
                break
            }
        }
    }

    /// Returns (range, font) pairs for CJK font fallback based on the system's
    /// preferred languages, or nil if no CJK language is detected. Each language
    /// only maps its own script ranges to avoid assigning glyphs to a font that
    /// lacks coverage (e.g. Hangul to Hiragino Sans).
    static func cjkFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [(String, String)]? {
        var mappings: [(String, String)] = []
        var coveredShared = false

        for lang in preferredLanguages {
            let lower = lang.lowercased()
            let font: String
            var langRanges: [String] = []

            if lower.hasPrefix("ja") {
                font = "Hiragino Sans"
                langRanges = japaneseRanges
            } else if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                font = "PingFang TC"
            } else if lower.hasPrefix("zh") {
                font = "PingFang SC"
            } else {
                continue
            }

            if !coveredShared {
                for range in sharedCJKRanges {
                    mappings.append((range, font))
                }
                coveredShared = true
            }

            for range in langRanges {
                mappings.append((range, font))
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Returns only the CJK mappings cmux should auto-inject after respecting
    /// explicit user overrides and the glyph coverage of the configured
    /// primary font family.
    static func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
        guard var mappings = cjkFontMappings(preferredLanguages: preferredLanguages) else { return nil }

        let summary = userFontConfigSummary(configPaths: configPaths)
        if summary.containsCodepointMap || summary.hasExplicitFontFamilyFallbackChain {
            return nil
        }

        guard let configuredFontFamily = summary.effectiveFontFamilies.first else {
            return mappings
        }

        if let rangeCoverageProbe {
            mappings.removeAll { range, _ in
                rangeCoverageProbe(configuredFontFamily, range)
            }
        } else if let configuredFont = configuredCTFont(named: configuredFontFamily) {
            mappings.removeAll { range, _ in
                fontContainsGlyphs(configuredFont, forRange: range)
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Checks whether the user's Ghostty config files already contain
    /// a `font-codepoint-map` entry covering CJK ranges. Also checks
    /// application-support config paths that cmux may load at runtime.
    static func userConfigContainsCJKCodepointMap(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).containsCodepointMap
    }

    static func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).hasExplicitFontFamilyFallbackChain
    }

    static func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        ) != nil
    }

    static func shouldApplyManagedDefaultAppearance(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userAppearanceConfigSummary(configPaths: configPaths).shouldApplyDefaultAppearance
    }

    static func conditionalThemeOverrideConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> String? {
        let summary = userAppearanceConfigSummary(configPaths: configPaths)
        guard let rawThemeValue = summary.lastThemeDirective else { return nil }

        let lightTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .light
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .dark
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty,
              !darkTheme.isEmpty,
              lightTheme.caseInsensitiveCompare(darkTheme) != .orderedSame else {
            return nil
        }

        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: preferredColorScheme
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTheme.isEmpty,
              resolvedTheme.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        return "theme = \(resolvedTheme)"
    }

    /// Resolve auto-injected CJK families through the regular-weight descriptor
    /// path first so locale-sensitive families such as Hiragino Sans don't fall
    /// back to ultra-light faces like W0 when Ghostty later matches by name.
    static func resolvedInjectedCJKFontName(
        named name: String,
        size: CGFloat = 12
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        guard let regularWeightFont = discoveredCTFont(named: trimmed, size: size, weightTrait: 0.0) else {
            return trimmed
        }

        let candidateNames = [
            CTFontCopyName(regularWeightFont, kCTFontFullNameKey) as String?,
            CTFontCopyName(regularWeightFont, kCTFontPostScriptNameKey) as String?,
        ].compactMap { $0 }
        let expectedFullName = CTFontCopyFullName(regularWeightFont) as String
        let expectedPostScriptName = CTFontCopyPostScriptName(regularWeightFont) as String

        for candidate in candidateNames {
            guard let verifiedFont = discoveredCTFont(named: candidate, size: size) else { continue }
            let verifiedNames = [
                CTFontCopyName(verifiedFont, kCTFontFamilyNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontFullNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontPostScriptNameKey) as String?,
            ].compactMap { $0 }
            let matchesRegularWeightFace = verifiedNames.contains {
                normalizedFontName($0) == normalizedFontName(expectedFullName) ||
                normalizedFontName($0) == normalizedFontName(expectedPostScriptName)
            }
            if matchesRegularWeightFace {
                return candidate
            }
        }

        return trimmed
    }

    private static func configuredCTFont(
        named name: String,
        size: CGFloat = 12
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateWithName(trimmed as CFString, size, nil)
        let normalizedRequestedName = normalizedFontName(trimmed)
        let resolvedNames = [
            kCTFontFamilyNameKey,
            kCTFontFullNameKey,
            kCTFontPostScriptNameKey,
        ].compactMap { CTFontCopyName(font, $0) as String? }

        guard resolvedNames.contains(where: { normalizedFontName($0) == normalizedRequestedName }) else {
            return nil
        }

        return font
    }

    /// Mirror Ghostty's family-name CoreText discovery path so injected
    /// `font-codepoint-map` values are validated against the same lookup mode.
    static func discoveredCTFont(
        named name: String,
        size: CGFloat = 12,
        weightTrait: CGFloat? = nil
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: trimmed,
            kCTFontSizeAttribute: size,
        ]
        if let weightTrait {
            attributes[kCTFontTraitsAttribute] = [
                kCTFontWeightTrait: weightTrait,
            ] as CFDictionary
        }

        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let match = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor])?.first else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(match, size, nil)
    }

    private static func fontContainsGlyphs(
        _ font: CTFont,
        forRange range: String
    ) -> Bool {
        guard let characters = cjkCoverageSampleCharactersByRange[range] else {
            return false
        }

        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let hasGlyphs = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return hasGlyphs && !glyphs.contains(0)
    }

    private static func normalizedFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func userFontConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserFontConfigSummary {
        var summary = UserFontConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    private static func userAppearanceConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserAppearanceConfigSummary {
        var summary = UserAppearanceConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanAppearanceConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanAppearanceConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    /// Returns the top-level Ghostty config paths cmux may load before
    /// recursive `config-file` processing.
    static func loadedGhosttyConfigScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        var paths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ]

        guard let appSupportDirectory else { return paths }

        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        paths.append(nativeConfig.path)
        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: configFileSize(at: nativeConfig),
            legacyConfigFileSize: configFileSize(at: nativeLegacyConfig)
        ) {
            paths.append(nativeLegacyConfig.path)
        }

        guard let bundleId = currentBundleIdentifier,
              !bundleId.isEmpty else { return paths }

        let appSupportConfigURLs = cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleId,
            appSupportDirectory: appSupportDirectory
        )
        paths.append(contentsOf: appSupportConfigURLs.map(\.path))

        let releaseDir = appSupportDirectory.appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
        let releaseLegacyConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        let releaseConfig = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)

        let releaseConfigSize = configFileSize(at: releaseConfig)
        let releaseLegacyConfigSize = configFileSize(at: releaseLegacyConfig)

        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: releaseConfigSize,
            legacyConfigFileSize: releaseLegacyConfigSize
        ), !paths.contains(releaseLegacyConfig.path) {
            paths.append(releaseLegacyConfig.path)
        }

        return paths
    }

    static func loadedCJKScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    private static func configFileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Scans a single config file for font settings relevant to cmux's
    /// injected CJK fallback and updates the pending recursive config-file
    /// queue using Ghostty's repeatable path semantics.
    private static func scanFontConfigFile(
        atPath path: String,
        summary: inout UserFontConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "font-codepoint-map":
                guard let value = entry.value else { continue }
                summary.applyFontCodepointMap(value)
            case "font-family":
                guard let value = entry.value else { continue }
                summary.recordFontFamily(value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
                    value,
                    valueWasQuoted: entry.valueWasQuoted,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    private static func scanAppearanceConfigFile(
        atPath path: String,
        summary: inout UserAppearanceConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "theme",
                 "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                summary.recordDirective(key: entry.key, value: entry.value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
                    value,
                    valueWasQuoted: entry.valueWasQuoted,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    private static func parsedConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?, valueWasQuoted: Bool)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWasQuoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")

        if valueWasQuoted {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value), valueWasQuoted)
    }

    private static func applyConfigFileDirective(
        _ value: String,
        valueWasQuoted: Bool,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        if value.isEmpty {
            recursiveConfigPaths.removeAll()
            return
        }

        var includePath = value
        if !valueWasQuoted, includePath.hasPrefix("?") {
            includePath.removeFirst()
            if includePath.count >= 2,
               includePath.hasPrefix("\""),
               includePath.hasSuffix("\"") {
                includePath.removeFirst()
                includePath.removeLast()
            }
        }
        guard !includePath.isEmpty else { return }

        let expanded = NSString(string: includePath).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (parentDir as NSString).appendingPathComponent(expanded)
        recursiveConfigPaths.append(absolute)
    }

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return newConfigFileSize == 0
    }

    static func shouldIncludeLegacyGhosttyConfigInScanPaths(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }

    static func shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> Bool {
        guard let appSupportDirectory else { return false }
        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        guard let legacyConfigSize = configFileSize(at: nativeLegacyConfig), legacyConfigSize > 0 else {
            return false
        }
        guard let nativeConfigSize = configFileSize(at: nativeConfig), nativeConfigSize > 0 else {
            return false
        }
        return true
    }

    static func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        CmuxGhosttyConfigPathResolver.loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }

    static func shouldApplyDefaultBackgroundUpdate(
        currentScope: GhosttyDefaultBackgroundUpdateScope,
        incomingScope: GhosttyDefaultBackgroundUpdateScope
    ) -> Bool {
        incomingScope.rawValue >= currentScope.rawValue
    }

    static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> Bool {
        previousColorScheme != currentColorScheme
    }

    enum AppearanceSynchronizationPlan {
        case unchanged
        case reload(
            colorScheme: GhosttyConfig.ColorSchemePreference,
            runtimeColorScheme: ghostty_color_scheme_e
        )

        var shouldReloadConfiguration: Bool {
            switch self {
            case .unchanged:
                return false
            case .reload:
                return true
            }
        }
    }

    enum RuntimeColorSchemeSynchronizationDecision: Equatable {
        case apply
        case skipReentrant
    }

    static func runtimeColorSchemeSynchronizationDecision(
        applied _: ghostty_color_scheme_e?,
        requested _: ghostty_color_scheme_e,
        isSynchronizing: Bool
    ) -> RuntimeColorSchemeSynchronizationDecision {
        if isSynchronizing {
            return .skipReentrant
        }
        return .apply
    }

    static func appearanceSynchronizationPlan(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> AppearanceSynchronizationPlan {
        guard shouldReloadConfigurationForAppearanceChange(
            previousColorScheme: previousColorScheme,
            currentColorScheme: currentColorScheme
        ) else {
            return .unchanged
        }

        return .reload(
            colorScheme: currentColorScheme,
            runtimeColorScheme: ghosttyRuntimeColorScheme(for: currentColorScheme)
        )
    }

    static func ghosttyRuntimeColorScheme(
        for colorScheme: GhosttyConfig.ColorSchemePreference
    ) -> ghostty_color_scheme_e {
        switch colorScheme {
        case .light:
            return GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark:
            return GHOSTTY_COLOR_SCHEME_DARK
        }
    }

    static func terminalRuntimeColorSchemePreference(
        forBackgroundColor backgroundColor: NSColor
    ) -> GhosttyConfig.ColorSchemePreference {
        cmuxReadableColorScheme(for: backgroundColor) == .light ? .light : .dark
    }

    static func runtimeColorSchemeForConfigLoad(
        source: String,
        requestedColorScheme: GhosttyConfig.ColorSchemePreference,
        effectiveTerminalColorScheme: GhosttyConfig.ColorSchemePreference,
        cmuxThemeValue: String?
    ) -> GhosttyConfig.ColorSchemePreference {
        guard GhosttySurfaceConfigurationRefresh.isCmuxThemeReloadSource(source),
              let cmuxThemeValue,
              GhosttyConfig.themeValueUsesSameResolvedThemeInBothColorSchemes(cmuxThemeValue) else {
            return requestedColorScheme
        }

        return effectiveTerminalColorScheme
    }

    static func shouldCaptureScrollLagEvent(
        samples: Int,
        averageMs: Double,
        maxMs: Double,
        thresholdMs: Double,
        minimumSamples: Int = 8,
        minimumAverageMs: Double = 12,
        nowUptime: TimeInterval,
        lastReportedUptime: TimeInterval?,
        cooldown: TimeInterval = 300
    ) -> Bool {
        guard samples >= minimumSamples else { return false }
        guard averageMs.isFinite, maxMs.isFinite, thresholdMs.isFinite, nowUptime.isFinite, cooldown.isFinite else {
            return false
        }
        guard averageMs >= minimumAverageMs else { return false }
        guard maxMs > thresholdMs else { return false }
        if let lastReportedUptime, nowUptime - lastReportedUptime < cooldown {
            return false
        }
        return true
    }

    private func loadCmuxAppSupportGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        guard let currentBundleIdentifier = Bundle.main.bundleIdentifier,
              !currentBundleIdentifier.isEmpty else { return }
        let urls = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )
        guard !urls.isEmpty else { return }

        for url in urls {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }

#if DEBUG
        cmuxDebugLog(
            "loaded cmux app support ghostty config from: \(urls.map(\.path).joined(separator: ", "))"
        )
        #endif
        #endif
    }

    private func currentCmuxAppSupportThemeValue() -> String? {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let urls = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )

        var lastValue: String?
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let value = GhosttyConfig.lastThemeDirective(in: contents) else {
                continue
            }
            lastValue = value
        }
        return lastValue
        #else
        return nil
        #endif
    }

    private func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        // Ghostty 1.3+ prefers `config.ghostty`, but some users still have their real
        // settings in the legacy `config` file. Use legacy only when `config.ghostty`
        // is absent or empty, so stale legacy files do not override current config.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        func fileSize(_ url: URL) -> Int? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            return size.intValue
        }

        guard Self.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: fileSize(configNew),
            legacyConfigFileSize: fileSize(configLegacy)
        ) else { return }

        configLegacy.path.withCString { path in
            ghostty_config_load_file(config, path)
        }

        #if DEBUG
        Self.initLog("loaded legacy ghostty config because config.ghostty was empty: \(configLegacy.path)")
        #endif
        #endif
    }

    /// Schedule a single tick on the main queue, coalescing multiple wakeups.
    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async {
            self.tick()
        }
    }

    func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()

        guard let app = app else { return }

        let start = CACurrentMediaTime()
        ghostty_app_tick(app)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if GhosttyTickNotificationDemand.isActive {
            NotificationCenter.default.post(name: .ghosttyDidTick, object: self)
        }

        // Track lag during scrolling
        if isScrolling {
            scrollLagSampleCount += 1
            scrollLagTotalMs += elapsedMs
            scrollLagMaxMs = max(scrollLagMaxMs, elapsedMs)
        }
    }

    func reloadConfiguration(
        soft: Bool = false,
        source: String = "unspecified",
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard reloadConfigurationDepth == 0 else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=reentrant")
            return
        }
        reloadConfigurationDepth += 1
        defer { reloadConfigurationDepth -= 1 }

        if reloadSettingsFromFile {
            KeyboardShortcutSettings.settingsFileStore.reload()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppDelegate.shared?.reloadCmuxConfigStores(source: source)
            }
        } else {
            DispatchQueue.main.sync {
                AppDelegate.shared?.reloadCmuxConfigStores(source: source)
            }
        }
        let reloadColorScheme = preferredColorScheme ?? GhosttyConfig.currentColorSchemePreference()
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            return
        }
        // Use the appearance preference while loading conditional theme pairs. For cmux
        // single-theme reloads, keep the resolved terminal scheme stable until the new
        // background is known so same-scheme theme changes do not flash through app mode.
        let loadColorScheme = Self.runtimeColorSchemeForConfigLoad(
            source: source,
            requestedColorScheme: reloadColorScheme,
            effectiveTerminalColorScheme: effectiveTerminalColorSchemePreference,
            cmuxThemeValue: currentCmuxAppSupportThemeValue()
        )
        synchronizeGhosttyRuntimeColorScheme(loadColorScheme, source: "reloadConfiguration:\(source):load")
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
            ghostty_app_update_config(app, config)
            lastAppearanceColorScheme = reloadColorScheme
            GhosttyConfig.invalidateLoadCache()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            scheduleSurfaceRefreshAfterConfigurationReload(
                source: source,
                preferredColorScheme: effectiveReloadColorScheme
            )
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            return
        }
        let renderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme
        )
        updateDefaultBackground(
            from: newConfig,
            source: "reloadConfiguration(source=\(source))",
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        GhosttyConfig.invalidateLoadCache()
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "reloadConfiguration(source=\(source))",
            preferredColorScheme: reloadColorScheme,
            baselineConfig: newConfig,
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
        synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
        ghostty_app_update_config(app, newConfig)
        DispatchQueue.main.async {
            self.applyBackgroundToKeyWindow()
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        lastAppearanceColorScheme = reloadColorScheme
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
        scheduleSurfaceRefreshAfterConfigurationReload(
            source: source,
            preferredColorScheme: effectiveReloadColorScheme
        )
        logThemeAction("reload end source=\(source) soft=\(soft) mode=full")
    }

    private func scheduleSurfaceRefreshAfterConfigurationReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        DispatchQueue.main.async {
            AppDelegate.shared?.refreshTerminalSurfacesAfterGhosttyConfigReload(
                source: source,
                preferredColorScheme: preferredColorScheme
            )
        }
    }

    func synchronizeThemeWithAppearance(_: NSAppearance?, source: String) {
        let currentColorScheme = GhosttyConfig.currentColorSchemePreference()
        let plan = Self.appearanceSynchronizationPlan(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme
        )
        if backgroundLogEnabled {
            let previousLabel: String
            switch lastAppearanceColorScheme {
            case .light:
                previousLabel = "light"
            case .dark:
                previousLabel = "dark"
            case nil:
                previousLabel = "nil"
            }
            let currentLabel: String = currentColorScheme == .dark ? "dark" : "light"
            logBackground(
                "appearance sync source=\(source) previous=\(previousLabel) current=\(currentLabel) reload=\(plan.shouldReloadConfiguration)"
            )
        }
        guard case let .reload(colorScheme, runtimeColorScheme) = plan else { return }
        synchronizeGhosttyRuntimeColorScheme(
            runtimeColorScheme,
            colorScheme: colorScheme,
            source: source
        )
        lastAppearanceColorScheme = colorScheme
        reloadConfiguration(
            source: "appearanceSync:\(source)",
            reloadSettingsFromFile: false,
            preferredColorScheme: colorScheme
        )
    }

    private func synchronizeGhosttyRuntimeColorScheme(
        _ colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        synchronizeGhosttyRuntimeColorScheme(
            Self.ghosttyRuntimeColorScheme(for: colorScheme),
            colorScheme: colorScheme,
            source: source
        )
    }

    private func synchronizeGhosttyRuntimeColorScheme(
        _ runtimeColorScheme: ghostty_color_scheme_e,
        colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        guard let app else { return }
        let decision = Self.runtimeColorSchemeSynchronizationDecision(
            applied: appliedGhosttyRuntimeColorScheme,
            requested: runtimeColorScheme,
            isSynchronizing: runtimeColorSchemeSynchronizationDepth > 0
        )
        guard decision == .apply else {
            if backgroundLogEnabled {
                let schemeLabel = colorScheme == .dark ? "dark" : "light"
                let reason: String
                switch decision {
                case .apply:
                    reason = "apply"
                case .skipReentrant:
                    reason = "reentrant"
                }
                logBackground("app color scheme skipped source=\(source) scheme=\(schemeLabel) reason=\(reason)")
            }
            return
        }

        appliedGhosttyRuntimeColorScheme = runtimeColorScheme
        runtimeColorSchemeSynchronizationDepth += 1
        defer { runtimeColorSchemeSynchronizationDepth -= 1 }
        ghostty_app_set_color_scheme(app, runtimeColorScheme)
        if backgroundLogEnabled {
            let schemeLabel = colorScheme == .dark ? "dark" : "light"
            logBackground("app color scheme source=\(source) scheme=\(schemeLabel)")
        }
    }

    private func shouldProcessGhosttyReloadAction(source: String, soft: Bool) -> Bool {
        guard reloadConfigurationDepth == 0,
              runtimeColorSchemeSynchronizationDepth == 0 else {
            logThemeAction("reload request skipped source=\(source) soft=\(soft) reason=reentrant")
            return false
        }
        return true
    }

    func openConfigurationInTextEdit() {
        #if os(macOS)
        let environment = ConfigSourceEnvironment.live()
        let fileURLs: [URL]
        do {
            fileURLs = try environment.materializedGhosttySettingsEditorURLs()
        } catch {
            NSSound.beep()
            return
        }
        guard !fileURLs.isEmpty else {
            NSSound.beep()
            return
        }
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(fileURLs, withApplicationAt: editorURL, configuration: configuration)
        #endif
    }

    private func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    @discardableResult
    private func setUsesHostLayerBackground(_ newValue: Bool, source: String) -> Bool {
        let previous = usesHostLayerBackground
        usesHostLayerBackground = newValue
        let hasChanged = previous != newValue
        if hasChanged, backgroundLogEnabled {
            logBackground(
                "terminal rendering mode changed source=\(source) usesHostLayerBackground=\(newValue) previous=\(previous)"
            )
        }
        return hasChanged
    }

    private func ghosttyColorValue(
        from config: ghostty_config_t,
        key: String,
        fallback: NSColor
    ) -> NSColor {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return fallback
        }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    private func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        forceNotify: Bool = false
    ) {
        guard let config else { return }

        let resolved = defaultBackgroundValues(from: config)
        applyDefaultBackground(
            color: resolved.backgroundColor,
            opacity: resolved.backgroundOpacity,
            backgroundBlur: resolved.backgroundBlur,
            foregroundColor: resolved.foregroundColor,
            cursorColor: resolved.cursorColor,
            cursorTextColor: resolved.cursorTextColor,
            selectionBackground: resolved.selectionBackground,
            selectionForeground: resolved.selectionForeground,
            source: source,
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private struct DefaultBackgroundValues {
        var backgroundColor: NSColor
        var backgroundOpacity: Double
        var backgroundBlur: GhosttyBackgroundBlur
        var foregroundColor: NSColor
        var cursorColor: NSColor
        var cursorTextColor: NSColor
        var selectionBackground: NSColor
        var selectionForeground: NSColor
    }

    private func defaultBackgroundValues(from config: ghostty_config_t?) -> DefaultBackgroundValues {
        let baseline = Self.fallbackAppearanceConfig
        guard let config else {
            return DefaultBackgroundValues(
                backgroundColor: baseline.backgroundColor,
                backgroundOpacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground
            )
        }

        let resolvedColor = ghosttyColorValue(from: config, key: "background", fallback: baseline.backgroundColor)
        let resolvedForeground = ghosttyColorValue(from: config, key: "foreground", fallback: baseline.foregroundColor)
        let resolvedCursor = ghosttyColorValue(from: config, key: "cursor-color", fallback: baseline.cursorColor)
        let resolvedCursorText = ghosttyColorValue(from: config, key: "cursor-text", fallback: baseline.cursorTextColor)
        let resolvedSelectionBackground = ghosttyColorValue(from: config, key: "selection-background", fallback: baseline.selectionBackground)
        let resolvedSelectionForeground = ghosttyColorValue(from: config, key: "selection-foreground", fallback: baseline.selectionForeground)
        var opacity = baseline.backgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        opacity = min(1.0, max(0.0, opacity))
        let backgroundBlur = defaultBackgroundBlurValue(from: config)
        return DefaultBackgroundValues(
            backgroundColor: resolvedColor,
            backgroundOpacity: opacity,
            backgroundBlur: backgroundBlur,
            foregroundColor: resolvedForeground,
            cursorColor: resolvedCursor,
            cursorTextColor: resolvedCursorText,
            selectionBackground: resolvedSelectionBackground,
            selectionForeground: resolvedSelectionForeground
        )
    }

    private func resolvedAppearanceValue<T>(
        parsedValue: T,
        baselineValue: T,
        unspecifiedFallbackValue: T,
        hasParsedDirective: Bool,
        hasDirective: Bool
    ) -> T {
        if hasParsedDirective {
            return parsedValue
        }
        if hasDirective {
            return baselineValue
        }
        return unspecifiedFallbackValue
    }

    private func updateDefaultBackgroundFromResolvedGhosttyConfig(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        useOnDiskResolvedConfig: Bool = true,
        forceNotify: Bool = false
    ) {
        let baseline = defaultBackgroundValues(from: baselineConfig)
        guard useOnDiskResolvedConfig else {
            applyDefaultBackground(
                color: baseline.backgroundColor,
                opacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground,
                source: source,
                scope: scope,
                forceNotify: forceNotify
            )
            return
        }
        let resolved = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        let fallbackForUnspecified = Self.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance()
            ? defaultBackgroundValues(from: nil)
            : baseline
        applyDefaultBackground(
            color: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundColor,
                hasParsedDirective: resolved.hasParsedBackgroundColor,
                hasDirective: resolved.hasBackgroundColorDirective
            ),
            opacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective: resolved.hasParsedBackgroundOpacity,
                hasDirective: resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundBlur,
                hasParsedDirective: resolved.hasParsedBackgroundBlur,
                hasDirective: resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.foregroundColor,
                hasParsedDirective: resolved.hasParsedForegroundColor,
                hasDirective: resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorColor,
                hasParsedDirective: resolved.hasParsedCursorColor,
                hasDirective: resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorTextColor,
                hasParsedDirective: resolved.hasParsedCursorTextColor,
                hasDirective: resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionBackground,
                hasParsedDirective: resolved.hasParsedSelectionBackground,
                hasDirective: resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionForeground,
                hasParsedDirective: resolved.hasParsedSelectionForeground,
                hasDirective: resolved.hasSelectionForegroundDirective
            ),
            source: "\(source).resolvedGhosttyConfig",
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private func defaultBackgroundBlurValue(from config: ghostty_config_t) -> GhosttyBackgroundBlur {
        var value: Int16 = 0
        let key = "background-blur"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .disabled
        }
        return GhosttyBackgroundBlur(cValue: value)
    }

    func focusFollowsMouseEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "focus-follows-mouse"
        let keyLength = UInt(key.lengthOfBytes(using: .utf8))
        let found = ghostty_config_get(config, &enabled, key, keyLength)
        return found && enabled
    }

    func scrollbarVisibility() -> ScrollbarVisibility {
        guard let config else { return .system }
        var value: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let value else {
            return .system
        }
        return ScrollbarVisibility(rawValue: String(cString: value)) ?? .system
    }

    func appleScriptAutomationEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "macos-applescript"
        _ = ghostty_config_get(config, &enabled, key, UInt(key.lengthOfBytes(using: .utf8)))
        return enabled
    }

    private func bellFeatures() -> CUnsignedInt {
        guard let config else { return 0 }
        var features: CUnsignedInt = 0
        let key = "bell-features"
        _ = ghostty_config_get(config, &features, key, UInt(key.lengthOfBytes(using: .utf8)))
        return features
    }

    private func bellAudioPath() -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "bell-audio-path"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let rawPath = value else {
            return nil
        }
        let path = String(cString: rawPath)
        return path.isEmpty ? nil : path
    }

    private func bellAudioVolume() -> Float {
        guard let config else { return 0.5 }
        var value: Double = 0.5
        let key = "bell-audio-volume"
        _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Float(min(1.0, max(0.0, value)))
    }

    private func ringBell() {
        let features = bellFeatures()

        if (features & (1 << 0)) != 0 {
            NSSound.beep()
        }

        if (features & (1 << 1)) != 0,
           let path = bellAudioPath(),
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = bellAudioVolume()
            bellAudioSound = sound
            if !sound.play() {
                bellAudioSound = nil
            }
        }

        if (features & (1 << 2)) != 0 {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        foregroundColor: NSColor? = nil,
        cursorColor: NSColor? = nil,
        cursorTextColor: NSColor? = nil,
        selectionBackground: NSColor? = nil,
        selectionForeground: NSColor? = nil,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope,
        forceNotify: Bool = false
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard Self.shouldApplyDefaultBackgroundUpdate(currentScope: previousScope, incomingScope: scope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        let previousBlur = defaultBackgroundBlur
        let previousForegroundHex = defaultForegroundColor.hexString()
        let previousCursorHex = defaultCursorColor.hexString()
        let previousCursorTextHex = defaultCursorTextColor.hexString()
        let previousSelectionBackgroundHex = defaultSelectionBackground.hexString()
        let previousSelectionForegroundHex = defaultSelectionForeground.hexString()
        let previousColorScheme = effectiveTerminalColorSchemePreference
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        defaultBackgroundBlur = backgroundBlur
        effectiveTerminalColorSchemePreference = Self.terminalRuntimeColorSchemePreference(
            forBackgroundColor: color
        )
        if let foregroundColor {
            defaultForegroundColor = foregroundColor
        }
        if let cursorColor {
            defaultCursorColor = cursorColor
        }
        if let cursorTextColor {
            defaultCursorTextColor = cursorTextColor
        }
        if let selectionBackground {
            defaultSelectionBackground = selectionBackground
        }
        if let selectionForeground {
            defaultSelectionForeground = selectionForeground
        }
        let hasChanged = forceNotify ||
            previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001 ||
            previousBlur != defaultBackgroundBlur ||
            previousForegroundHex != defaultForegroundColor.hexString() ||
            previousCursorHex != defaultCursorColor.hexString() ||
            previousCursorTextHex != defaultCursorTextColor.hexString() ||
            previousSelectionBackgroundHex != defaultSelectionBackground.hexString() ||
            previousSelectionForegroundHex != defaultSelectionForeground.hexString() ||
            previousColorScheme != effectiveTerminalColorSchemePreference
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default appearance updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousBg=\(previousHex) previousFg=\(previousForegroundHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) previousBlur=\(previousBlur) previousScheme=\(previousColorScheme) bg=\(defaultBackgroundColor.hexString()) fg=\(defaultForegroundColor.hexString()) cursor=\(defaultCursorColor.hexString()) cursorText=\(defaultCursorTextColor.hexString()) selectionBg=\(defaultSelectionBackground.hexString()) selectionFg=\(defaultSelectionForeground.hexString()) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur) scheme=\(effectiveTerminalColorSchemePreference) changed=\(hasChanged) forced=\(forceNotify)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source,
                foregroundColor: defaultForegroundColor,
                cursorColor: defaultCursorColor,
                cursorTextColor: defaultCursorTextColor,
                selectionBackground: defaultSelectionBackground,
                selectionForeground: defaultSelectionForeground
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    private func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    private func actionLabel(for action: ghostty_action_s) -> String {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: action.tag)
        }
    }

    private func logAction(_ action: ghostty_action_s, target: ghostty_target_s, tabId: UUID?, surfaceId: UUID?) {
        guard backgroundLogEnabled else { return }
        let targetLabel = target.tag == GHOSTTY_TARGET_SURFACE ? "surface" : "app"
        logBackground(
            "action event target=\(targetLabel) action=\(actionLabel(for: action)) tab=\(tabId?.uuidString ?? "nil") surface=\(surfaceId?.uuidString ?? "nil")"
        )
    }

    private func color(from change: ghostty_action_color_change_s) -> NSColor {
        NSColor(
            red: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1.0
        )
    }

    private func colorKindLabel(_ kind: ghostty_action_color_kind_e) -> String {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            return "foreground"
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            return "background"
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            return "cursor"
        default:
            return "palette:\(kind.rawValue)"
        }
    }

    @MainActor
    private func applyAppColorChange(
        _ change: ghostty_action_color_change_s,
        source: String
    ) {
        let newColor = color(from: change)
        switch change.kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            applyDefaultBackground(
                color: newColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                source: source,
                scope: .app
            )
            DispatchQueue.main.async {
                self.applyBackgroundToKeyWindow()
            }
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                foregroundColor: newColor,
                source: source,
                scope: .app
            )
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                cursorColor: newColor,
                source: source,
                scope: .app
            )
        default:
            if backgroundLogEnabled {
                logBackground(
                    "app color change ignored kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=\(source)"
                )
            }
        }
    }

    private func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    @MainActor
    private static func openEmbeddedBrowserLink(
        url: URL,
        sourceWorkspaceId: UUID,
        sourcePanelId: UUID,
        host: String
    ) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
            #if DEBUG
            cmuxDebugLog("link.openURL deferred embedded but cmuxBrowser=disabled, opening externally url=\(url)")
            #endif
            return NSWorkspace.shared.open(url)
        }

        guard let app = AppDelegate.shared,
              let resolved = app.workspaceContainingPanel(
                panelId: sourcePanelId,
                preferredWorkspaceId: sourceWorkspaceId
              ) else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded but workspace lookup failed, opening externally " +
                "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        let workspace = resolved.workspace
        #if DEBUG
        if workspace.id != sourceWorkspaceId {
            cmuxDebugLog(
                "link.openURL workspace.remap sourceTab=\(sourceWorkspaceId) " +
                "resolvedTab=\(workspace.id) surfaceId=\(sourcePanelId)"
            )
        }
        #endif

        let openedInBrowser: Bool
        if let targetPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            #if DEBUG
            cmuxDebugLog("link.openURL opening in existing browser pane=\(targetPane)")
            #endif
            openedInBrowser = workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        } else {
            #if DEBUG
            cmuxDebugLog("link.openURL opening as new browser split from surface=\(sourcePanelId)")
            #endif
            openedInBrowser = workspace.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, url: url) != nil
        }

        guard openedInBrowser else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded browser creation failed, opening externally " +
                "host=\(host) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        return true
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func runtimeApp(from userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func registerRuntimeApp(_ runtimeApp: GhosttyApp, for app: ghostty_app_t) {
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        appRegistry[key] = runtimeApp
        appRegistryLock.unlock()
    }

    private static func setInitializingRuntimeApp(_ runtimeApp: GhosttyApp?) {
        appRegistryLock.lock()
        initializingRuntimeApp = runtimeApp
        appRegistryLock.unlock()
    }

    private static func runtimeApp(for app: ghostty_app_t?) -> GhosttyApp? {
        guard let app else { return nil }
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        return appRegistry[key]
    }

    private static func runtimeAppForActionCallback(_ app: ghostty_app_t?) -> GhosttyApp? {
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        if let app {
            let key = UInt(bitPattern: app)
            if let registered = appRegistry[key] {
                return registered
            }
        }
        return initializingRuntimeApp
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
                action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
                action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                logAction(action, target: target, tabId: nil, surfaceId: nil)
            }

            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                return performOnMain {
                    guard let tabManager = AppDelegate.shared?.tabManager,
                          let tabId = tabManager.selectedTabId else {
                        return false
                    }
                    let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? tabManager
                    let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                    if let workspace = owningManager.tabs.first(where: { $0.id == tabId }),
                       workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                        return true
                    }
                    let tabTitle = owningManager.titleForTab(tabId) ?? "Terminal"
                    let command = actionTitle.isEmpty ? tabTitle : actionTitle
                    let body = actionBody
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                    return true
                }
            }

            if action.tag == GHOSTTY_ACTION_RING_BELL {
                performOnMain {
                    self.ringBell()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                logThemeAction("reload request target=app soft=\(soft)")
                performOnMain {
                    guard self.shouldProcessGhosttyReloadAction(
                        source: "action.reload_config.app",
                        soft: soft
                    ) else {
                        return
                    }
                    self.reloadConfiguration(soft: soft, source: "action.reload_config.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                performOnMain {
                    applyAppColorChange(action.action.color_change, source: "action.color_change.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                // Theme picker preview reloads are resolved through reloadConfiguration.
                // Ghostty's config-change payload can still contain stale app defaults,
                // so it must not own the window chrome appearance.
                synchronizeGhosttyRuntimeColorScheme(
                    effectiveTerminalColorSchemePreference,
                    source: "action.config_change.app:resolved"
                )
                DispatchQueue.main.async {
                    self.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        let callbackContext = Self.callbackContext(from: ghostty_surface_userdata(target.target.surface))
        let callbackTabId = callbackContext?.tabId
        let callbackSurfaceId = callbackContext?.surfaceId

        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            // The child (shell) exited. Ghostty will fall back to printing
            // "Process exited. Press any key..." into the terminal unless the host
            // handles this action. For cmux, the correct behavior is to close
            // the panel immediately (no prompt).
#if DEBUG
            cmuxDebugLog(
                "surface.action.showChildExited tab=\(callbackTabId?.uuidString.prefix(5) ?? "nil") " +
                "surface=\(callbackSurfaceId?.uuidString.prefix(5) ?? "nil")"
            )
#endif
#if DEBUG
            cmuxWriteChildExitProbe(
                [
                    "probeShowChildExitedTabId": callbackTabId?.uuidString ?? "",
                    "probeShowChildExitedSurfaceId": callbackSurfaceId?.uuidString ?? "",
                ],
                increments: ["probeShowChildExitedCount": 1]
            )
#endif
            // Keep host-close async to avoid re-entrant close/deinit while Ghostty is still
            // dispatching this action callback.
            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                if let callbackTabId,
                   let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    manager.closePanelAfterChildExited(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }
            }
            // Always report handled so Ghostty doesn't print the fallback prompt.
            return true
        }

        guard let surfaceView = callbackContext?.surfaceView else { return false }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            logAction(
                action,
                target: target,
                tabId: callbackTabId ?? surfaceView.tabId,
                surfaceId: callbackSurfaceId ?? surfaceView.terminalSurface?.id
            )
        }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split) else {
                return false
            }
            return performOnMain {
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
                    return false
                }
                return tabManager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
            }
        case GHOSTTY_ACTION_RING_BELL:
            performOnMain {
                self.ringBell()
            }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split) else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction) else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_RENDER:
            return false
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.enqueueScrollbarUpdate(scrollbar)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            DispatchQueue.main.async {
                surfaceView.cellSize = cellSize
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateCellSize,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.cellSize: cellSize]
                )
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.surfaceId: surfaceId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            performOnMain {
                let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? AppDelegate.shared?.tabManager
                if let workspace = owningManager?.tabs.first(where: { $0.id == tabId }),
                   workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                    return
                }
                let tabTitle = owningManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            let newColor = color(from: change)
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                if backgroundLogEnabled {
                    logBackground(
                        "surface override set tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(newColor.hexString()) default=\(defaultBackgroundColor.hexString()) source=action.color_change.surface"
                    )
                }
                DispatchQueue.main.async { [self] in
                    surfaceView.backgroundColor = newColor
                    surfaceView.applySurfaceBackground()
                    if backgroundLogEnabled {
                        logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                    }
                    surfaceView.applyWindowBackgroundIfActive()
                }
            } else if backgroundLogEnabled {
                logBackground(
                    "surface color change observed tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=action.color_change.surface"
                )
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            DispatchQueue.main.async { [self] in
                if let staleOverride = surfaceView.backgroundColor {
                    surfaceView.backgroundColor = nil
                    if backgroundLogEnabled {
                        logBackground(
                            "surface override cleared tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") cleared=\(staleOverride.hexString()) source=action.config_change.surface"
                        )
                    }
                    surfaceView.applySurfaceBackground()
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            // Keep surface config-change handling scoped to the surface. The app-level
            // default background is owned by reloadConfiguration's resolved GhosttyConfig.
            let effectiveConfigChangeColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(
                effectiveConfigChangeColorScheme,
                source: "action.config_change.surface:resolved"
            )
            DispatchQueue.main.async {
                surfaceView.applySurfaceColorScheme(
                    force: true,
                    preferredColorScheme: effectiveConfigChangeColorScheme
                )
            }
            if backgroundLogEnabled {
                logBackground(
                    "surface config change deferred terminal bg apply tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(surfaceView.backgroundColor?.hexString() ?? "nil") default=\(defaultBackgroundColor.hexString())"
                )
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            let source = "action.reload_config.surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")"
            logThemeAction(
                "reload request target=surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") soft=\(soft)"
            )
            return performOnMain {
                guard self.shouldProcessGhosttyReloadAction(source: source, soft: soft) else {
                    return true
                }
                let preferredColorScheme = self.effectiveTerminalColorSchemePreference
                surfaceView.terminalSurface?.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                    preferredColorScheme: preferredColorScheme
                )
                self.reloadSurfaceConfiguration(
                    target.target.surface,
                    soft: soft,
                    source: source,
                    preferredColorScheme: preferredColorScheme
                )
                surfaceView.terminalSurface?.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                surfaceView.terminalSurface?.forceRefresh(reason: "surface.reloadConfig")
                return true
            }
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                surfaceView.updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                surfaceView.updateKeyTable(action.action.key_table)
                return true
            }
        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let cstr = openUrl.url else { return false }
            let urlString = String(
                data: Data(bytes: cstr, count: Int(openUrl.len)),
                encoding: .utf8
            ) ?? ""
            #if DEBUG
            cmuxDebugLog("link.openURL raw=\(urlString)")
            #endif

            // Try file-path resolution before URL classification.
            // Ghostty's link detection can match file paths that contain
            // slashes or dots (e.g. "docs/spec.md." or "/tmp/spec.md.") as URLs.
            // Attempt to resolve the raw string as a local file first
            // (with trailing-punctuation trimming via cmuxResolveQuicklookPath).
            // If the file exists and cmux can handle it, route through the
            // file viewer instead of the browser.
            let trimmedUrlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalizedOpenURLString = urlString
            if !trimmedUrlString.isEmpty {
                let filePathResolution: (routed: Bool, fallbackPath: String?) = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id) else {
                        return (false, nil)
                    }
                    let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(
                        workspace: workspace,
                        surfaceId: termSurface.id
                    )
                    guard let resolvedPath = cmuxResolveTerminalOpenURLFilePath(trimmedUrlString, cwd: cwd) else {
                        return (false, nil)
                    }
                    guard CommandClickFileOpenRouter.shouldRouteInCmux(path: resolvedPath) else {
                        return (false, resolvedPath)
                    }
                    #if DEBUG
                    cmuxDebugLog("link.openURL resolvedAsFilePath=\(resolvedPath)")
                    #endif
                    let fileURL = URL(fileURLWithPath: resolvedPath)
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: resolvedPath
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return (true, resolvedPath)
                }
                if let fallbackPath = filePathResolution.fallbackPath {
                    normalizedOpenURLString = fallbackPath
                }
                if filePathResolution.routed {
                    return true
                }
            }

            guard let target = resolveTerminalOpenURLTarget(normalizedOpenURLString) else {
                #if DEBUG
                cmuxDebugLog("link.openURL resolve failed, returning false")
                #endif
                return false
            }
            // Route local file URLs into cmux when the file-routing toggle is on.
            // URL fragments/queries are stripped (the panel only needs the file
            // path), so links emitted by tools like Claude Code (`foo.md#L42`)
            // still route into the viewer. Anything else (toggle off, hosted
            // file URL, remote workspace, unreadable file, split creation
            // failure) falls through to the existing NSWorkspace path below so
            // URL semantics are preserved.
            let fileURLHost = target.url.host
            if target.url.isFileURL,
               fileURLHost == nil || fileURLHost?.isEmpty == true || fileURLHost == "localhost" {
                let fileURL = target.url
                let routed: Bool = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id),
                          CommandClickFileOpenRouter.shouldRouteInCmux(path: fileURL.path) else {
                        return false
                    }
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: fileURL.path
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return true
                }
                if routed {
                    return true
                }
                // Fall through to the existing NSWorkspace path below.
            }

            if !BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser() {
                #if DEBUG
                cmuxDebugLog("link.openURL cmuxBrowser=disabled, opening externally url=\(target.url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(target.url)
                }
            }
            switch target {
            case let .external(url):
                #if DEBUG
                cmuxDebugLog("link.openURL target=external, opening externally url=\(url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(url)
                }
            case let .embeddedBrowser(url):
                if BrowserLinkOpenSettings.shouldOpenExternally(url) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but shouldOpenExternally=true url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but normalizeHost=nil host=\(url.host ?? "nil") url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // If a host whitelist is configured and this host isn't in it, open externally.
                if !BrowserLinkOpenSettings.hostMatchesWhitelist(host) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but hostWhitelist miss host=\(host) url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                let sourceWorkspaceId = callbackTabId ?? surfaceView.tabId
                let sourcePanelId = callbackSurfaceId ?? surfaceView.terminalSurface?.id
                guard let sourceWorkspaceId,
                      let sourcePanelId else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but tabId/surfaceId=nil")
                    #endif
                    return false
                }
                #if DEBUG
                cmuxDebugLog(
                    "link.openURL target=embedded, opening in browser pane " +
                    "host=\(host) url=\(url) tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId)"
                )
                #endif
                let canAttemptEmbeddedOpen = performOnMain {
                    BrowserAvailabilitySettings.isEnabled() &&
                    AppDelegate.shared?.workspaceContainingPanel(
                        panelId: sourcePanelId,
                        preferredWorkspaceId: sourceWorkspaceId
                    ) != nil
                }
                guard canAttemptEmbeddedOpen else {
                    #if DEBUG
                    cmuxDebugLog(
                        "link.openURL embedded preflight failed, opening externally " +
                        "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
                    )
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // Browser split creation changes focus, which unfocuses the source terminal and
                // calls back into Ghostty. Defer that work until this open_url callback returns.
                // From here cmux owns the open attempt and the deferred path falls back externally.
                Task { @MainActor [url, sourceWorkspaceId, sourcePanelId, host] in
                    let didOpen = Self.openEmbeddedBrowserLink(
                        url: url,
                        sourceWorkspaceId: sourceWorkspaceId,
                        sourcePanelId: sourcePanelId,
                        host: host
                    )
                    guard didOpen else {
                        #if DEBUG
                        cmuxDebugLog("link.openURL deferred open failed url=\(url)")
                        #endif
                        NSSound.beep()
                        return
                    }
                }
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        let snapshot = WindowAppearanceSnapshot.currentFromUserDefaults(app: self)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if backgroundLogEnabled {
            logBackground(
                "applied window backdrop phase=\(plan.hostingPhase.rawValue) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur)"
            )
        }
    }

    func applyWindowBlurIfNeeded(_ window: NSWindow) {
        guard let app = self.app else { return }
        // ghostty_set_window_background_blur reads background-blur and
        // background-opacity from the app config internally and calls
        // CGSSetWindowBackgroundBlurRadius, a compositor-level setter that is
        // idempotent.  It is a no-op when opacity >= 1.0 or blur is disabled,
        // so we can call it unconditionally whenever the window is transparent.
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if let raw = keyWindow?.identifier?.rawValue,
           raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
            return keyWindow
        }
        return NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        })
    }

    func logBackground(_ message: String) {
        let timestamp = Self.backgroundLogTimestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - backgroundLogStartUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        backgroundLogLock.lock()
        defer { backgroundLogLock.unlock() }
        backgroundLogSequence &+= 1
        let sequence = backgroundLogSequence
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Debug Render Instrumentation

private enum GhosttyRenderedFrameNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

private enum GhosttyTickNotificationDemand {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static func retain() -> () -> Void {
        lock.lock()
        count += 1
        lock.unlock()

        return {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

/// Lightweight instrumentation to detect whether Ghostty is actually requesting Metal drawables.
/// This helps catch "frozen until refocus" regressions without relying on screenshots (which can
/// mask redraw issues by forcing a window server flush).
final class GhosttyMetalLayer: CAMetalLayer {
    private let lock = NSLock()
    private var drawableCount: Int = 0
    private var lastDrawableTime: CFTimeInterval = 0
    private weak var surfaceView: GhosttyNSView?

    func setSurfaceView(_ surfaceView: GhosttyNSView?) {
        lock.lock()
        self.surfaceView = surfaceView
        lock.unlock()
    }

    private func currentSurfaceView() -> GhosttyNSView? {
        lock.lock()
        defer { lock.unlock() }
        return surfaceView
    }

    func debugStats() -> (count: Int, last: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (drawableCount, lastDrawableTime)
    }

    override func nextDrawable() -> CAMetalDrawable? {
        guard let drawable = super.nextDrawable() else { return nil }
        lock.lock()
        drawableCount += 1
        lastDrawableTime = CACurrentMediaTime()
        lock.unlock()
        guard GhosttyRenderedFrameNotificationDemand.isActive else { return drawable }
        if let surfaceView = currentSurfaceView() {
            DispatchQueue.main.async { [weak surfaceView] in
                surfaceView?.enqueueRenderedFrameUpdate()
            }
        }
        return drawable
    }
}

final class TerminalSurfaceRegistry {
    static let shared = TerminalSurfaceRegistry()

    private let lock = NSLock()
    private let surfaces = NSHashTable<AnyObject>.weakObjects()
    private var runtimeSurfaceOwners: [UInt: UUID] = [:]
    private var surfaceFocusPlacements: [UUID: TerminalSurfaceFocusPlacement] = [:]

    private init() {}

    func register(_ surface: TerminalSurface) {
        lock.lock()
        defer { lock.unlock() }
        surfaces.add(surface)
        surfaceFocusPlacements[surface.id] = surface.focusPlacement
    }

    func unregister(_ surface: TerminalSurface) {
        lock.lock()
        let surfaceId = surface.id
        surfaces.remove(surface)
        let stillRegistered = surfaces.allObjects
            .compactMap { $0 as? TerminalSurface }
            .contains { $0 !== surface && $0.id == surfaceId }
        if !stillRegistered {
            surfaceFocusPlacements.removeValue(forKey: surfaceId)
        }
        lock.unlock()

        Task { @MainActor in
            AppDelegate.shared?.retireRecoverableMainWindowRoutesWithoutRegisteredTerminalSurfaces(
                reason: "terminalSurface.unregister"
            )
        }
    }

    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        runtimeSurfaceOwners[UInt(bitPattern: surface)] = ownerId
    }

    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let key = UInt(bitPattern: surface)
        guard runtimeSurfaceOwners[key] == ownerId else { return }
        runtimeSurfaceOwners.removeValue(forKey: key)
    }

    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeSurfaceOwners[UInt(bitPattern: surface)]
    }

    func surface(id: UUID) -> TerminalSurface? {
        lock.lock()
        let object = surfaces.allObjects.compactMap { $0 as? TerminalSurface }.first { $0.id == id }
        lock.unlock()
        return object
    }

    func isRightSidebarDockSurface(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return surfaceFocusPlacements[id] == .rightSidebarDock
    }

    func allSurfaces() -> [TerminalSurface] {
        lock.lock()
        let objects = surfaces.allObjects.compactMap { $0 as? TerminalSurface }
        lock.unlock()
        return objects.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// Core Image filter that cuts a pane-local terminal fill out of the shared window backdrop.
private final class TerminalSharedBackdropCutoutFilter: CIFilter {
    private static let filterInputKeys = [kCIInputImageKey, kCIInputBackgroundImageKey]
    private static let filterOutputKeys = [kCIOutputImageKey]

    /// The mask image supplied by AppKit for the cutout view.
    @objc dynamic var inputImage: CIImage?

    /// The already-rendered shared backdrop behind the terminal surface.
    @objc dynamic var inputBackgroundImage: CIImage?

    /// Input keys advertised to AppKit's Core Image compositing pipeline.
    override var inputKeys: [String] {
        Self.filterInputKeys
    }

    /// Output keys advertised to AppKit's Core Image compositing pipeline.
    override var outputKeys: [String] {
        Self.filterOutputKeys
    }

    /// The backdrop image with the cutout mask removed.
    override var outputImage: CIImage? {
        guard let inputImage, let inputBackgroundImage else { return nil }
        return CIBlendKernel.destinationOut.apply(
            foreground: inputImage,
            background: inputBackgroundImage
        )
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

enum TerminalSurfaceFocusPlacement: Equatable {
    case workspace
    case rightSidebarDock
}

private func recordAgentHibernationTerminalInput(workspaceId: UUID, panelId: UUID) {
    guard AgentHibernationTrackingGate.isEnabled() else { return }
    let recordedAt = Date()
    Task { @MainActor in
        AgentHibernationController.shared.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: recordedAt
        )
    }
}

final class TerminalSurface: Identifiable, ObservableObject {
    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private struct PendingKeyEvent {
        let keycode: UInt32
        let mods: ghostty_input_mods_e
        let label: String

        var queuedByteCost: Int {
            max(label.utf8.count, 1)
        }
    }

    private enum PendingSocketInput {
        case pasteText(Data)
        case inputText(Data)
        /// Bytes that must be processed as terminal output, not user input.
        case processOutput(Data)
        case key(PendingKeyEvent)

        var estimatedBytes: Int {
            switch self {
            case .pasteText(let data), .inputText(let data), .processOutput(let data):
                return data.count
            case .key(let event):
                return event.queuedByteCost
            }
        }
    }

    private enum ParsedSocketInput {
        case rawBytes(Data)
        /// A complete terminal string control sequence such as OSC, DCS, PM, or APC.
        case terminalBytes(Data)
        case key(PendingKeyEvent)
    }

    private static let committedTextInputChunkByteLimit = 96

    enum NamedKeySendResult: Equatable {
        case sent
        case queued
        case unknownKey
        case inputQueueFull
        case surfaceUnavailable
        case processExited

        /// Whether the named key was delivered to the surface or queued for an
        /// imminently-started surface. `false` means the key never reached the PTY.
        var accepted: Bool {
            switch self {
            case .sent, .queued:
                return true
            case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    enum InputSendResult: Equatable {
        case sent
        case queued
        case inputQueueFull
        case surfaceUnavailable
        case processExited

        var accepted: Bool {
            switch self {
            case .sent, .queued:
                return true
            case .inputQueueFull, .surfaceUnavailable, .processExited:
                return false
            }
        }
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?

    /// Whether the runtime Ghostty surface exists and has not begun teardown.
    ///
    /// Use this as a quick availability check. Before passing `surface` to
    /// Ghostty C APIs that dereference the pointer (e.g.
    /// `ghostty_surface_inherited_config`, `ghostty_surface_quicklook_font`),
    /// call `liveSurfaceForGhosttyAccess(reason:)` so stale freed pointers are
    /// rejected and quarantined.
    var hasLiveSurface: Bool { surface != nil && portalLifecycleState == .live }

    /// Whether the terminal surface view is currently attached to a window.
    ///
    /// Use the hosted view rather than the inner surface view, since the surface can be
    /// temporarily unattached (surface not yet created / reparenting) even while the panel
    /// is already in the window.
    var uiWindow: NSWindow? {
        guard let window = hostedView.window else { return nil }
        if let headlessStartupWindow, window === headlessStartupWindow {
            return nil
        }
        return window
    }

    var isViewInWindow: Bool { uiWindow != nil }

    func isHeadlessStartupWindow(_ window: NSWindow?) -> Bool {
        guard let window, let headlessStartupWindow else { return false }
        return window === headlessStartupWindow
    }
    let id: UUID
    private(set) var tabId: UUID
    /// Port ordinal for CMUX_PORT range assignment. Captured at construction so
    /// every runtime startup path uses the same immutable workspace port range.
    private let portOrdinal: Int
    /// Snapshotted once per app session so all workspaces use consistent values
    private static let sessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portBaseKey)
        return val > 0 ? val : AutomationSettings.defaultPortBase
    }()
    private static let sessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portRangeKey)
        return val > 0 ? val : AutomationSettings.defaultPortRange
    }()
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: CmuxSurfaceConfigTemplate?
    private let workingDirectory: String?
    let initialCommand: String?
    let tmuxStartCommand: String?
    let initialInput: String?
    private var nextRuntimeInitialInput: String?
    private let initialEnvironmentOverrides: [String: String]
    var requestedWorkingDirectory: String? { workingDirectory }
    let focusPlacement: TerminalSurfaceFocusPlacement
    private var additionalEnvironment: [String: String]
    var respawnInitialEnvironmentOverrides: [String: String] {
        initialEnvironmentOverrides
    }
    var respawnAdditionalEnvironment: [String: String] {
        var environment = additionalEnvironment
        environment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)
        return environment
    }
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastUncappedPixelWidth: UInt32 = 0
    private var lastUncappedPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0
    private var mobileViewportCellLimit: (columns: Int, rows: Int)?
    private let debugMetadataLock = NSLock()
    private let createdAt: Date = Date()
    private var runtimeSurfaceCreatedAt: Date?
    private var teardownRequestedAt: Date?
    private var teardownRequestReason: String?
    // Main-thread only. Public socket send entrypoints are MainActor-isolated
    // before reading `surface` or mutating this pending queue.
    private var pendingSocketInputQueue: [PendingSocketInput] = []
    private var pendingSocketInputBytes: Int = 0
    private let maxPendingSocketInputBytes = 1_048_576
    private var backgroundSurfaceStartQueued = false
    private var runtimeSurfaceSuspendedForAgentHibernation = false
    private var headlessStartupWindow: NSWindow?
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?
    private var claudeCommandShim: ClaudeCommandShim?
    private var claudeCommandShimInstallTask: Task<ClaudeCommandShim?, Never>?
    private var claudeCommandShimInstallCompleted = false
    /// Heap-allocated userdata for the libghostty PTY tee callback (cmux
    /// fork extension). Installed in `createSurface` after
    /// `ghostty_surface_new` succeeds; released alongside
    /// `surfaceCallbackContext` whenever we tear down or rebuild the
    /// surface. The Mac sync server reads the tee'd bytes to broadcast
    /// raw PTY output to paired iPhones (`MobileTerminalByteTee`).
    private var mobileByteTeeContext: Unmanaged<MobileTerminalByteTeeUserdata>?
    /// The desired focus state for the Ghostty C surface. May be set before the
    /// C surface exists (e.g. during layout restoration); `createSurface`
    /// reapplies this value once the runtime surface exists, then keeps using it
    /// as a dedup guard to avoid redundant `ghostty_surface_set_focus` calls
    /// (prevents prompt redraws with P10k).
    ///
    /// Start unfocused and only opt into focus when the workspace/AppKit focus
    /// path explicitly requests it so background panes do not keep a focused
    /// state unless the workspace focus path requests it.
    private var desiredFocusState: Bool = false
    private(set) var clipboardReadGeneration = 0
#if DEBUG
    private var needsConfirmCloseOverrideForTesting: Bool?
    private var runtimeSurfaceFreedOutOfBandForTesting = false
    private var runtimeSurfaceCreateAttemptCountForTesting = 0
    private let debugForceRefreshCountLock = NSLock()
    private var debugForceRefreshCountValue = 0
    @MainActor
    static var runtimeSurfaceFreeOverrideForTesting: (@Sendable (ghostty_surface_t) -> Void)?
#endif
    private enum PortalLifecycleState: String {
        case live
        case closing
        case closed
    }
    private struct PortalHostLease {
        let hostId: ObjectIdentifier
        let paneId: UUID
        let instanceSerial: UInt64
        let inWindow: Bool
        let area: CGFloat
    }
    private var portalLifecycleState: PortalLifecycleState = .live
    private var portalLifecycleGeneration: UInt64 = 1
    private var activePortalHostLease: PortalHostLease?
    @Published var searchState: SearchState? = nil {
	        didSet {
	            if let searchState {
	                hostedView.cancelFocusRequest()
#if DEBUG
                cmuxDebugLog("find.searchState created tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
#if DEBUG
                        cmuxDebugLog("find.needle updated tab=\(self?.tabId.uuidString.prefix(5) ?? "?") surface=\(self?.id.uuidString.prefix(5) ?? "?") chars=\(needle.count)")
#endif
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if let oldValue {
                lastSearchNeedle = oldValue.needle
                searchNeedleCancellable = nil
#if DEBUG
                cmuxDebugLog("find.searchState cleared tab=\(tabId.uuidString.prefix(5)) surface=\(id.uuidString.prefix(5))")
#endif
                _ = performBindingAction("end_search")
            }
        }
    }
    @Published private(set) var keyboardCopyModeActive: Bool = false
    private(set) var lastSearchNeedle = ""
    private var searchNeedleCancellable: AnyCancellable?
    var currentKeyStateIndicatorText: String? { surfaceView.currentKeyStateIndicatorText }

    private static func cmuxContextEnvironment(
        workspaceId: UUID,
        surfaceId: UUID,
        socketPath: String
    ) -> CmuxContextEnvironment {
        CmuxContextEnvironment(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPath: socketPath
        )
    }

    /// Pre-spawn lookup for managed context keys and explicit startup overrides.
    /// Full runtime-only values such as bundle, port, PATH, and shell-integration
    /// entries are assembled when a Ghostty surface is created.
    @MainActor
    func startupEnvironmentValue(_ key: String) -> String? {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &environment,
            protectedKeys: &protectedKeys
        )
        return Self.mergedStartupEnvironment(
            base: environment,
            protectedKeys: protectedKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )[key]
    }

    init(
        id: UUID = UUID(),
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: CmuxSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace
    ) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.id = id
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.portOrdinal = portOrdinal
        let trimmedCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialCommand = (trimmedCommand?.isEmpty == false) ? trimmedCommand : nil
        let trimmedTmuxStartCommand = tmuxStartCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmuxStartCommand = (trimmedTmuxStartCommand?.isEmpty == false) ? trimmedTmuxStartCommand : nil
        let trimmedInput = initialInput?.isEmpty == false ? initialInput : nil
        self.initialInput = trimmedInput
        self.initialEnvironmentOverrides = Self.mergedNormalizedEnvironment(base: [:], overrides: initialEnvironmentOverrides)
        self.additionalEnvironment = Self.mergedNormalizedEnvironment(base: [:], overrides: additionalEnvironment)
        self.focusPlacement = focusPlacement
        // Match Ghostty's own SurfaceView: ensure a non-zero initial frame so the backing layer
        // has non-zero bounds and the renderer can initialize without presenting a blank/stretched
        // intermediate frame on the first real resize.
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        TerminalSurfaceRegistry.shared.register(self)
        self.hostedView.attachSurface(self)

        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        let hasStartupWork = self.initialCommand != nil
            || self.tmuxStartCommand != nil
            || trimmedInput != nil
            || inheritedCommand?.isEmpty == false
            || inheritedInput?.isEmpty == false

        // Surfaces with startup work must spawn before the user focuses their workspace.
        // Ghostty's embedded surface creation still expects a view with a window, so use
        // a hidden bootstrap window until the real portal host is ready.
        if hasStartupWork {
            MainActor.assumeIsolated {
                scheduleHeadlessRuntimeStartIfNeeded(reason: "startup")
            }
        }
    }

    func debugWaitAfterCommand() -> Bool {
        configTemplate?.waitAfterCommand ?? false
    }

    var launchContext: ghostty_surface_context_e {
        surfaceContext
    }

    func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }

    @MainActor
    private func scheduleHeadlessRuntimeStartIfNeeded(reason: String) {
        startRuntimeUsingHeadlessWindowIfNeeded(reason: reason)
    }

    @MainActor
    private func startRuntimeUsingHeadlessWindowIfNeeded(reason: String) {
        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        ensureHeadlessStartupWindowIfNeeded(reason: reason)
        hostedView.attachSurface(self)
    }

    @MainActor
    private func ensureHeadlessStartupWindowIfNeeded(reason: String) {
        guard headlessStartupWindow == nil else { return }
        guard hostedView.window == nil else { return }

        let width = max(surfaceView.bounds.width, CGFloat(800))
        let height = max(surfaceView.bounds.height, CGFloat(600))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let contentView = NSView(frame: frame)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.contentView = contentView
        headlessStartupWindow = window
        hostedView.setVisibleInUI(false)
        hostedView.setActive(false)

#if DEBUG
        cmuxDebugLog(
            "surface.headless_window.create surface=\(id.uuidString.prefix(8)) " +
            "reason=\(reason) window=\(ObjectIdentifier(window))"
        )
#endif
    }

    @MainActor
    private func releaseHeadlessStartupWindowIfNeeded(for view: GhosttyNSView) {
        guard let window = headlessStartupWindow else { return }
        guard let currentWindow = view.window, currentWindow !== window else { return }
        headlessStartupWindow = nil
        window.contentView = nil
        window.close()
#if DEBUG
        cmuxDebugLog(
            "surface.headless_window.release surface=\(id.uuidString.prefix(8)) " +
            "realWindow=\(ObjectIdentifier(currentWindow))"
        )
#endif
    }

    private func closeHeadlessStartupWindowIfNeeded() {
        let startupWindow = headlessStartupWindow
        headlessStartupWindow = nil
        guard let startupWindow else { return }

        let closeStartupWindow = {
            startupWindow.contentView = nil
            startupWindow.close()
        }
        if Thread.isMainThread {
            closeStartupWindow()
        } else {
            DispatchQueue.main.async(execute: closeStartupWindow)
        }
    }

    @MainActor
    func reconcileAttachedWindowIfNeeded(for view: GhosttyNSView) {
        guard attachedView === view else { return }
        releaseHeadlessStartupWindowIfNeeded(for: view)
        guard let screen = view.window?.screen ?? NSScreen.main,
              let displayID = screen.displayID,
              displayID != 0 else { return }
        guard let s = liveSurfaceForGhosttyAccess(reason: "reconcileAttachedWindow") else { return }
        ghostty_surface_set_display_id(s, displayID)
    }

    private static func mergedNormalizedEnvironment(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var merged: [String: String] = [:]
        merged.reserveCapacity(base.count + overrides.count)
        for (rawKey, value) in base {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        for (rawKey, value) in overrides {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            merged[key] = value
        }
        return merged
    }

    func isAttached(to view: GhosttyNSView) -> Bool {
        attachedView === view && surface != nil
    }

    func portalBindingGeneration() -> UInt64 {
        portalLifecycleGeneration
    }

    func portalBindingStateLabel() -> String {
        portalLifecycleState.rawValue
    }

    private func withDebugMetadataLock<T>(_ body: () -> T) -> T {
        debugMetadataLock.lock()
        defer { debugMetadataLock.unlock() }
        return body()
    }

    func debugCreatedAt() -> Date {
        withDebugMetadataLock { createdAt }
    }

    func debugRuntimeSurfaceCreatedAt() -> Date? {
        withDebugMetadataLock { runtimeSurfaceCreatedAt }
    }

    func debugTeardownRequest() -> (requestedAt: Date?, reason: String?) {
        withDebugMetadataLock { (teardownRequestedAt, teardownRequestReason) }
    }

    func debugLastKnownWorkspaceId() -> UUID {
        tabId
    }

    func debugSurfaceContextLabel() -> String {
        cmuxSurfaceContextName(surfaceContext)
    }

    func debugPortalHostLease() -> (hostId: String?, paneId: UUID?, inWindow: Bool?, area: CGFloat?) {
        guard let activePortalHostLease else {
            return (nil, nil, nil, nil)
        }
        return (
            hostId: String(describing: activePortalHostLease.hostId),
            paneId: activePortalHostLease.paneId,
            inWindow: activePortalHostLease.inWindow,
            area: activePortalHostLease.area
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard portalLifecycleState == .live else { return false }
        if let expectedSurfaceId, expectedSurfaceId != id {
            return false
        }
        if let expectedGeneration, expectedGeneration != portalLifecycleGeneration {
            return false
        }
        return true
    }

    @MainActor
    func liveSurfaceForGhosttyAccess(reason: String) -> ghostty_surface_t? {
        guard hasLiveSurface, let surface else { return nil }
        let registry = TerminalSurfaceRegistry.shared
        let registeredOwnerId = registry.runtimeSurfaceOwnerId(surface)
        guard registeredOwnerId == id,
              cmuxSurfacePointerAppearsLive(surface) else {
            let callbackContext = surfaceCallbackContext
            surfaceCallbackContext = nil
            let teeContext = mobileByteTeeContext
            mobileByteTeeContext = nil
            registry.unregisterRuntimeSurface(surface, ownerId: id)
            self.surface = nil
            activePortalHostLease = nil
            recordTeardownRequest(reason: reason)
            markPortalLifecycleClosed(reason: reason)
#if DEBUG
            let registeredOwnerToken = registeredOwnerId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "surface.lifecycle.stale surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
                "registryOwner=\(registeredOwnerToken)"
            )
#endif
            callbackContext?.release()
            teeContext?.release()
            return nil
        }
        return surface
    }

    /// Forward a mobile scroll gesture to this real surface. libghostty does the
    /// mode-correct thing: a normal screen moves the viewport into scrollback;
    /// an alt screen with mouse reporting encodes mouse-wheel to the PTY for the
    /// program (vim/less/htop). `col`/`row` is the grid cell under the finger so
    /// the alt-screen wheel reports at the right cell. Runs on the main actor
    /// like the desktop's own scroll path.
    @MainActor
    func mobileScroll(deltaLines: Double, col: Int, row: Int) {
        guard deltaLines != 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "mobileScroll") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(col) + 0.5) * cellWidthPt
        let posY = (Double(row) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_scroll(surface, 0, deltaLines, 0)
    }

    /// Forward a mobile tap to this real surface as a left mouse click at the
    /// given grid cell. libghostty does the mode-correct thing: a program with
    /// mouse reporting (alt-screen TUIs like lazygit/htop/fzf) gets an encoded
    /// click report to its PTY; a normal screen treats it as an empty selection,
    /// which is harmless. `col`/`row` is the grid cell under the finger. Runs on
    /// the main actor like the desktop's own click path.
    @MainActor
    func mobileClick(col: Int, row: Int) {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileClick") else { return }
        let size = ghostty_surface_size(surface)
        // The surface is sized in backing pixels; `ghostty_surface_mouse_pos`
        // wants points, so divide the cell size by the content scale. Aim at the
        // cell center so the click lands unambiguously inside the target cell.
        let scale = max(Double(lastXScale), 1)
        let cellWidthPt = Double(size.cell_width_px) / scale
        let cellHeightPt = Double(size.cell_height_px) / scale
        let posX = (Double(max(0, col)) + 0.5) * cellWidthPt
        let posY = (Double(max(0, row)) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    private static let portalHostAreaThreshold: CGFloat = 4

    private static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    private static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    @discardableResult
    func preparePortalHostReplacementIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        // SwiftUI can tear down and rebuild the host NSView during split churn. Keep the
        // existing portal binding alive, but make the old lease non-usable so the next
        // distinct host in the same pane can claim immediately instead of waiting for a
        // later layout-follow-up retry.
        activePortalHostLease = PortalHostLease(
            hostId: current.hostId,
            paneId: current.paneId,
            instanceSerial: current.instanceSerial,
            inWindow: false,
            area: current.area
        )
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        instanceSerial: UInt64,
        inWindow: Bool,
        bounds: CGRect,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if current.hostId == hostId {
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            // During split churn SwiftUI can briefly keep the old host alive while the new
            // host for the same pane is already in the window. Prefer the newer live host
            // immediately so the surface moves with the pane instead of waiting for a later
            // update from unrelated focus/layout work.
            let newerSamePaneHostReady =
                current.paneId == paneId.id &&
                nextUsable &&
                next.instanceSerial > current.instanceSerial
            // A dragged terminal must hand off immediately when it moves to a different pane.
            // Waiting for the old host to become "worse" leaves the moved pane blank/stale.
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                newerSamePaneHostReady

            if shouldReplace {
#if DEBUG
                cmuxDebugLog(
                    "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) " +
                    "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) " +
                    "replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            cmuxDebugLog(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) " +
                "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) " +
                "ownerArea=\(String(format: "%.1f", current.area))"
            )
#endif
            return false
        }

        activePortalHostLease = next
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) " +
            "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) replacingHost=nil"
        )
#endif
        return true
    }

    func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) {
        guard let current = activePortalHostLease, current.hostId == hostId else { return }
        activePortalHostLease = nil
#if DEBUG
        cmuxDebugLog(
            "terminal.portal.host.release surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
    }

    private func recordTeardownRequest(reason: String) {
        withDebugMetadataLock {
            if teardownRequestedAt == nil {
                teardownRequestedAt = Date()
            }
            if let existing = teardownRequestReason, !existing.isEmpty {
                return
            }
            teardownRequestReason = reason
        }
    }

    private func recordRuntimeSurfaceCreation() {
        withDebugMetadataLock {
            runtimeSurfaceCreatedAt = Date()
        }
    }

    private func allowsRuntimeSurfaceCreation() -> Bool {
        portalLifecycleState == .live && !runtimeSurfaceSuspendedForAgentHibernation
    }

    private var hasDeferredStartupWork: Bool {
        let inheritedCommand = configTemplate?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedInput = configTemplate?.initialInput
        return initialCommand != nil ||
            tmuxStartCommand != nil ||
            initialInput != nil ||
            inheritedCommand?.isEmpty == false ||
            inheritedInput?.isEmpty == false ||
            pendingSocketInputBytes > 0
    }

    func hasDeferredStartupWorkForBackgroundStart() -> Bool {
        hasDeferredStartupWork
    }

    func beginPortalCloseLifecycle(reason: String) {
        guard portalLifecycleState != .closed else { return }
        guard portalLifecycleState != .closing else { return }
        recordTeardownRequest(reason: reason)
        portalLifecycleState = .closing
        portalLifecycleGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.close.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    private func markPortalLifecycleClosed(reason: String) {
        guard portalLifecycleState != .closed else { return }
        portalLifecycleState = .closed
        portalLifecycleGeneration &+= 1
#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.close.sealed surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason) " +
            "generation=\(portalLifecycleGeneration)"
        )
#endif
    }

    /// Explicitly free the Ghostty runtime surface. Idempotent — safe to call
    /// before deinit; deinit will skip the free if already torn down.
    @MainActor
    func teardownSurface() {
        recordTeardownRequest(reason: "surface.teardown")
        markPortalLifecycleClosed(reason: "teardown")
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        MobileTerminalByteTee.shared.dropSurface(surfaceID: id)

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            teeContext?.release()
            return
        }
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            enqueueTerminalSurfaceRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: "teardown",
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; teeContext is not
            // transported through the request, so release it here.
            teeContext?.release()
            return
        }
#endif

        Task { @MainActor in
            // Keep free behavior aligned with deinit: perform the runtime teardown on
            // the next main-actor turn so SIGHUP delivery is deterministic but non-reentrant.
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            teeContext?.release()
        }
    }

    @MainActor
    func suspendRuntimeSurfaceForAgentHibernation(reason: String) {
        runtimeSurfaceSuspendedForAgentHibernation = true
        backgroundSurfaceStartQueued = false
        closeHeadlessStartupWindowIfNeeded()
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        MobileTerminalByteTee.shared.dropSurface(surfaceID: id)

        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil
        activePortalHostLease = nil
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        desiredFocusState = false

        guard let surfaceToFree else {
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.hibernate surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif

#if DEBUG
        if let freeSurface = Self.runtimeSurfaceFreeOverrideForTesting {
            enqueueTerminalSurfaceRuntimeTeardown(
                id: id,
                workspaceId: tabId,
                reason: reason,
                surface: surfaceToFree,
                callbackContext: callbackContext,
                freeSurface: freeSurface
            )
            // The teardown coordinator releases callbackContext; teeContext is not
            // transported through the request, so release it here.
            teeContext?.release()
            return
        }
#endif

        Task { @MainActor in
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
            teeContext?.release()
        }
    }

#if DEBUG
    private static let surfaceLogPath = "/tmp/cmux-ghostty-surface.log"
    private static let sizeLogPath = "/tmp/cmux-ghostty-size.log"

    func debugCurrentPixelSize() -> (width: UInt32, height: UInt32) {
        (lastPixelWidth, lastPixelHeight)
    }

    func debugDesiredFocusState() -> Bool {
        desiredFocusState
    }

    @MainActor
    func debugAdditionalEnvironmentForTesting() -> [String: String] {
        additionalEnvironment
    }

    func debugForceRefreshCount() -> Int {
        debugForceRefreshCountLock.lock()
        defer { debugForceRefreshCountLock.unlock() }
        return debugForceRefreshCountValue
    }

    @MainActor
    func resetDebugForceRefreshCount() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue = 0
        debugForceRefreshCountLock.unlock()
    }

    private func recordDebugForceRefresh() {
        debugForceRefreshCountLock.lock()
        debugForceRefreshCountValue += 1
        debugForceRefreshCountLock.unlock()
    }

    private static func surfaceLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: surfaceLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: surfaceLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func sizeLog(_ message: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1" else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: sizeLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: sizeLogPath, contents: line.data(using: .utf8))
        }
    }
    #endif

    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up).
    private func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) {
            return UInt32.max
        }
        return UInt32(floored)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    private func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    @MainActor
    func attachToView(_ view: GhosttyNSView) {
#if DEBUG
        cmuxDebugLog(
            "surface.attach surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque()) " +
            "attached=\(attachedView != nil ? 1 : 0) hasSurface=\(surface != nil ? 1 : 0) inWindow=\(view.window != nil ? 1 : 0)"
        )
#endif

        // If already attached to this view, nothing to do.
        // Still re-assert the display id: during split close tree restructuring, the view can be
        // removed/re-added (or briefly have window/screen nil) without recreating the surface.
        // Ghostty's vsync-driven renderer depends on having a valid display id; if it is missing
        // or stale, the surface can appear visually frozen until a focus/visibility change.
        // SwiftUI also re-enters this path for ordinary state propagation (drag hover, active
        // markers, visibility flags), so avoid forcing a geometry refresh when the attachment
        // itself is unchanged.
        if attachedView === view && surface != nil {
            releaseHeadlessStartupWindowIfNeeded(for: view)
#if DEBUG
            cmuxDebugLog("surface.attach.reuse surface=\(id.uuidString.prefix(5)) view=\(Unmanaged.passUnretained(view).toOpaque())")
#endif
            if let screen = view.window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0,
               let s = surface {
                ghostty_surface_set_display_id(s, displayID)
            }
            return
        }

        if let attachedView, attachedView !== view {
#if DEBUG
            cmuxDebugLog(
                "surface.attach.skip surface=\(id.uuidString.prefix(5)) reason=alreadyAttachedToDifferentView " +
                "current=\(Unmanaged.passUnretained(attachedView).toOpaque()) new=\(Unmanaged.passUnretained(view).toOpaque())"
            )
#endif
            return
        }

        attachedView = view
        releaseHeadlessStartupWindowIfNeeded(for: view)

        // Ordinary portal attachment can arrive before AppKit has put the view in
        // a window. Defer those. Startup and cold-input paths install the owned
        // view in a hidden bootstrap window first, then come through here.
        if surface == nil {
            guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
                cmuxDebugLog(
                    "surface.attach.skip surface=\(id.uuidString.prefix(5)) " +
                    "reason=lifecycle.\(portalLifecycleState.rawValue)"
                )
#endif
                return
            }
            guard view.window != nil else {
#if DEBUG
                cmuxDebugLog(
                    "surface.attach.defer surface=\(id.uuidString.prefix(5)) reason=noWindow " +
                    "bounds=\(String(format: "%.1fx%.1f", Double(view.bounds.width), Double(view.bounds.height)))"
                )
#endif
                return
            }
#if DEBUG
            cmuxDebugLog(
                "surface.attach.create surface=\(id.uuidString.prefix(5)) " +
                "inWindow=\(view.window != nil ? 1 : 0)"
            )
#endif
            createSurface(for: view)
#if DEBUG
            cmuxDebugLog("surface.attach.create.done surface=\(id.uuidString.prefix(5)) hasSurface=\(surface != nil ? 1 : 0)")
#endif
        } else if let screen = view.window?.screen ?? NSScreen.main,
                  let displayID = screen.displayID,
                  displayID != 0,
                  let s = surface {
            // Surface exists but we're (re)attaching after a view hierarchy move; ensure display id.
            ghostty_surface_set_display_id(s, displayID)
#if DEBUG
            cmuxDebugLog("surface.attach.displayId surface=\(id.uuidString.prefix(5)) display=\(displayID)")
#endif
        }
    }

    @MainActor
    private func claudeCommandShimStateForSurface(view: GhosttyNSView) -> (isReady: Bool, shim: ClaudeCommandShim?) {
        guard let wrapperURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux-claude-wrapper") else {
            claudeCommandShimInstallCompleted = true
            return (true, nil)
        }

        if claudeCommandShimInstallCompleted {
            return (true, claudeCommandShim)
        }

        if claudeCommandShimInstallTask == nil {
            let surfaceId = id
            let installTask = Task.detached(priority: .utility) {
                Self.installClaudeCommandShimIfPossible(wrapperURL: wrapperURL, surfaceId: surfaceId)
            }
            claudeCommandShimInstallTask = installTask
            Task { @MainActor [weak self, weak view] in
                let shim = await installTask.value
                guard let self else { return }
                self.claudeCommandShim = shim
                self.claudeCommandShimInstallCompleted = true
                self.claudeCommandShimInstallTask = nil
                guard self.allowsRuntimeSurfaceCreation(), self.surface == nil else { return }
                if let view, view.window != nil {
                    self.createSurface(for: view)
                } else if let attachedView = self.attachedView, attachedView.window != nil {
                    self.createSurface(for: attachedView)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "claude-shim-ready")
                }
            }
        }

        return (false, nil)
    }

    @MainActor
    private func createSurface(for view: GhosttyNSView) {
        guard allowsRuntimeSurfaceCreation() else {
#if DEBUG
            cmuxDebugLog(
                "surface.create.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=lifecycle.\(portalLifecycleState.rawValue)"
            )
            Self.surfaceLog(
                "createSurface SKIPPED surface=\(id.uuidString) tab=\(tabId.uuidString) lifecycle=\(portalLifecycleState.rawValue)"
            )
#endif
            return
        }
        let claudeShimState = claudeCommandShimStateForSurface(view: view)
        guard claudeShimState.isReady else { return }
        let claudeShim = claudeShimState.shim
#if DEBUG
        runtimeSurfaceCreateAttemptCountForTesting += 1
#endif
        #if DEBUG
        let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap { String(cString: $0) } ?? "(unset)"
        let terminfo = getenv("TERMINFO").flatMap { String(cString: $0) } ?? "(unset)"
        let xdg = getenv("XDG_DATA_DIRS").flatMap { String(cString: $0) } ?? "(unset)"
        let manpath = getenv("MANPATH").flatMap { String(cString: $0) } ?? "(unset)"
        Self.surfaceLog("createSurface start surface=\(id.uuidString) tab=\(tabId.uuidString) bounds=\(view.bounds) inWindow=\(view.window != nil) resources=\(resourcesDir) terminfo=\(terminfo) xdg=\(xdg) manpath=\(manpath)")
        #endif

        guard let app = GhosttyApp.shared.app else {
            #if DEBUG
            cmuxDebugLog("ghostty.surface.create.failed reason=appNotInitialized surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty app not initialized")
            #endif
            return
        }

        let scaleFactors = scaleFactors(for: view)

        let baseConfig = configTemplate ?? CmuxSurfaceConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.font_size = baseConfig.fontSize
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(surfaceView: view, terminalSurface: self))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
#if DEBUG
        let templateFontText = String(format: "%.2f", surfaceConfig.font_size)
        cmuxDebugLog(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(cmuxSurfaceContextName(surfaceContext)) " +
            "templateFont=\(templateFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        Self.applyManagedCmuxContextEnvironment(
            Self.cmuxContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                socketPath: socketPath
            ),
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("CMUX_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(inheritedClaudeConfigDir)
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            setManagedEnvironmentValue("CMUX_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("CMUX_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace (base/range snapshotted once per app session)
        do {
            let startPort = Self.sessionPortBase + portOrdinal * Self.sessionPortRangeSize
            setManagedEnvironmentValue("CMUX_PORT", String(startPort))
            setManagedEnvironmentValue("CMUX_PORT_END", String(startPort + Self.sessionPortRangeSize - 1))
            setManagedEnvironmentValue("CMUX_PORT_RANGE", String(Self.sessionPortRangeSize))
        }

        let claudeHooksEnabled = ClaudeCodeIntegrationSettings.hooksEnabled()
        if !claudeHooksEnabled {
            setManagedEnvironmentValue("CMUX_CLAUDE_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = ClaudeCodeIntegrationSettings.customClaudePath() {
            setManagedEnvironmentValue("CMUX_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedEnvironmentValue(
            AgentSubagentNotificationSettings.environmentKey,
            AgentSubagentNotificationSettings.suppressNotifications() ? "1" : "0"
        )
        if !CursorIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_CURSOR_HOOKS_DISABLED", "1")
        }
        if !GeminiIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_GEMINI_HOOKS_DISABLED", "1")
        }
        if !KiroIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedEnvironmentValue(
            "CMUX_KIRO_NOTIFICATION_LEVEL",
            KiroIntegrationSettings.notificationLevel().rawValue
        )
        if !AmpIntegrationSettings.hooksEnabled() {
            setManagedEnvironmentValue("CMUX_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedEnvironmentValue(
                    "PATH",
                    Self.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let claudeShim {
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM", claudeShim.executablePath)
            setManagedEnvironmentValue("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", claudeShim.directoryPath)
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(claudeShim.directoryPath, to: currentPath)
            )
        }

        // Shell integration: inject ZDOTDIR wrapper for zsh shells.
        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path {
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("CMUX_SHELL_INTEGRATION_DIR", integrationDir)
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard),
                showPullRequestsEnabled: SidebarWorkspaceDetailDefaults.showPullRequestsValue(defaults: .standard),
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                if GhosttyApp.shared.userGhosttyShellIntegrationMode != "none" {
                    setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION", "1")
                }
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        setManagedEnvironmentValue("CMUX_ZSH_ZDOTDIR", candidateZdotdir)
                    }
                }

                setManagedEnvironmentValue("ZDOTDIR", integrationDir)
            } else if shellName == "bash" {
                if GhosttyApp.shared.userGhosttyShellIntegrationMode != "none" {
                    setManagedEnvironmentValue("CMUX_LOAD_GHOSTTY_BASH_INTEGRATION", "1")
                }
                // macOS ships /bin/bash 3.2, where Ghostty's automatic bash
                // integration is unsupported and HOME-based wrapper startup is
                // not reliable. Bootstrap cmux bash integration on the first
                // interactive prompt by exporting the shared bootstrap script as
                // PROMPT_COMMAND. The script lives in Resources/shell-integration
                // so the app and the regression test share one source of truth
                // (see issue #5164). Doc comments and blank lines are stripped so
                // users never see them in $PROMPT_COMMAND; the test mirrors this.
                let bashBootstrapPath = (integrationDir as NSString)
                    .appendingPathComponent("cmux-bash-bootstrap.bash")
                do {
                    let rawBootstrap = try String(contentsOfFile: bashBootstrapPath, encoding: .utf8)
                    let bootstrap = rawBootstrap
                        .components(separatedBy: "\n")
                        .filter { line in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                        }
                        .joined(separator: "\n")
                    if !bootstrap.isEmpty {
                        setManagedEnvironmentValue("PROMPT_COMMAND", bootstrap)
                    }
                } catch {
                    // The bootstrap ships in the app bundle alongside
                    // cmux-bash-integration.bash, so a read failure means a
                    // corrupt/partial bundle. Surface it (with the underlying
                    // error) in unified logging rather than silently leaving bash
                    // without cmux integration. The path is logged privately so
                    // user-specific install paths are not exposed in the log.
                    Logger(subsystem: "com.cmuxterm.app", category: "ghostty.initialization")
                        .error("cmux bash bootstrap unreadable at \(bashBootstrapPath, privacy: .private): \(error.localizedDescription, privacy: .public); bash shell integration will not load")
                }
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        env["CMUX_SOCKET"] = ""

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand: String? = {
            if let initialCommand, !initialCommand.isEmpty {
                return initialCommand
            }
            return baseConfig.command
        }()
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedInitialInput: String? = {
            if let runtimeInitialInput, !runtimeInitialInput.isEmpty {
                return runtimeInitialInput
            }
            if let initialInput, !initialInput.isEmpty {
                return initialInput
            }
            return baseConfig.initialInput
        }()
        func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let value else {
                return body(nil)
            }
            return value.withCString(body)
        }

        let createWithCommandAndWorkingDirectory = {
            withOptionalCString(resolvedCommand) { cCommand in
                surfaceConfig.command = cCommand
                withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                    surfaceConfig.working_directory = cWorkingDir
                    withOptionalCString(resolvedInitialInput) { cInitialInput in
                        surfaceConfig.initial_input = cInitialInput
                        createSurface()
                    }
                }
            }
        }

        createWithCommandAndWorkingDirectory()

        if surface == nil {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            #if DEBUG
            cmuxDebugLog("ghostty.surface.create.failed reason=surfaceNewNil surface=\(id.uuidString)")
            #endif
            #if DEBUG
            Self.surfaceLog("createSurface FAILED surface=\(id.uuidString): ghostty_surface_new returned nil")
            if let cfg = GhosttyApp.shared.config {
                let count = Int(ghostty_config_diagnostics_count(cfg))
                Self.surfaceLog("createSurface diagnostics count=\(count)")
                for i in 0..<count {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
                    Self.surfaceLog("  [\(i)] \(msg)")
                }
            } else {
                Self.surfaceLog("createSurface diagnostics: config=nil")
            }
            #endif
            return
        }
        guard let createdSurface = surface else { return }
        TerminalSurfaceRegistry.shared.registerRuntimeSurface(createdSurface, ownerId: id)
        recordRuntimeSurfaceCreation()
        // Install the PTY tee so MobileTerminalByteTee receives every byte
        // the read thread produces, in order, before the VT parser runs.
        // Paired iPhones consume these bytes via `terminal.bytes` events
        // and feed them into their own libghostty surface, guaranteeing
        // grid parity by construction. The userdata box is released
        // alongside `surfaceCallbackContext` when the surface tears down.
        mobileByteTeeContext?.release()
        let teeContext = Unmanaged.passRetained(MobileTerminalByteTeeUserdata(surfaceID: id))
        ghostty_surface_set_pty_tee_cb(
            createdSurface,
            cmuxMobileTerminalByteTeeCallback,
            teeContext.toOpaque()
        )
        mobileByteTeeContext = teeContext
        if runtimeInitialInput != nil {
            nextRuntimeInitialInput = nil
        }

        // Session scrollback replay must be one-shot. Reusing it on a later runtime
        // surface recreation would inject stale restored output into a live shell.
        additionalEnvironment.removeValue(forKey: SessionScrollbackReplayStore.environmentKey)

        // For vsync-driven rendering, Ghostty needs to know which display we're on so it can
        // start a CVDisplayLink with the right refresh rate. If we don't set this early, the
        // renderer can believe vsync is "running" but never deliver frames, which looks like a
        // frozen terminal until focus/visibility changes force a synchronous draw.
        //
        // `view.window?.screen` can be transiently nil during early attachment; fall back to the
        // primary screen so we always set *some* display ID, then update again on screen changes.
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            ghostty_surface_set_size(createdSurface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastUncappedPixelWidth = wpx
            lastUncappedPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        // Some GhosttyKit builds can drop inherited font_size during post-create
        // config/scale reconciliation. If runtime points don't match the inherited
        // template points, re-apply via binding action so all creation paths
        // (new surface, split, new workspace) preserve zoom from the source terminal.
        if let inheritedFontPoints = configTemplate?.fontSize,
           inheritedFontPoints > 0 {
            let currentFontPoints = cmuxCurrentSurfaceFontSizePoints(createdSurface)
            let shouldReapply = {
                guard let currentFontPoints else { return true }
                return abs(currentFontPoints - inheritedFontPoints) > 0.05
            }()
            if shouldReapply {
                let action = String(format: "set_font_size:%.3f", inheritedFontPoints)
                _ = performBindingAction(action)
            }
        }

        // Re-apply the desired focus state after creation so the live runtime
        // surface converges with any focus changes that happened while the
        // surface was being initialized.
        ghostty_surface_set_focus(createdSurface, desiredFocusState)

        flushPendingSocketInputIfNeeded()

        // Kick an initial draw after creation/size setup. On some startup paths Ghostty can
        // miss the first vsync callback and sit on a blank frame until another focus/visibility
        // transition nudges the renderer.
        view.forceRefreshSurface()
        ghostty_surface_refresh(createdSurface)

        NotificationCenter.default.post(
            name: .terminalSurfaceDidBecomeReady,
            object: self,
            userInfo: [
                "surfaceId": id,
                "workspaceId": tabId
            ]
        )

#if DEBUG
        let runtimeFontText = cmuxCurrentSurfaceFontSizePoints(createdSurface).map {
            String(format: "%.2f", $0)
        } ?? "nil"
        cmuxDebugLog(
            "zoom.create.done surface=\(id.uuidString.prefix(5)) context=\(cmuxSurfaceContextName(surfaceContext)) " +
            "runtimeFont=\(runtimeFontText)"
        )
#endif
    }

    @discardableResult
    @MainActor
    func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        layerScale: CGFloat,
        backingSize: CGSize? = nil
    ) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "updateSize") else { return false }
        _ = layerScale

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let rawWpx = pixelDimension(from: resolvedBackingWidth)
        let rawHpx = pixelDimension(from: resolvedBackingHeight)
        lastUncappedPixelWidth = rawWpx
        lastUncappedPixelHeight = rawHpx
        let cappedSize = cappedByMobileViewportLimit(width: rawWpx, height: rawHpx, surface: surface)
        let wpx = cappedSize.width
        let hpx = cappedSize.height
        guard wpx > 0, hpx > 0 else { return false }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight

        #if DEBUG
        Self.sizeLog("updateSize-call surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) changed=\((scaleChanged || sizeChanged) ? 1 : 0)")
        #endif

        if mobileViewportCellLimit != nil {
            updateMobileViewportBorder(
                appliedWidth: wpx,
                appliedHeight: hpx,
                baseWidth: rawWpx,
                baseHeight: rawHpx
            )
        }

        guard scaleChanged || sizeChanged else { return false }

        #if DEBUG
        if sizeChanged {
            let win = attachedView?.window != nil ? "1" : "0"
            Self.sizeLog("updateSize surface=\(id.uuidString.prefix(8)) size=\(wpx)x\(hpx) prev=\(lastPixelWidth)x\(lastPixelHeight) win=\(win)")
        }
        #endif

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }

        // Let Ghostty continue rendering on its own wakeups for steady-state frames.
        return true
    }

    @discardableResult
    @MainActor
    func applyMobileViewportLimit(columns: Int, rows: Int, reason: String) -> Bool {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "applyMobileViewportLimit") else {
            hostedView.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)
            return false
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        let targetWidth = safePixelDimension(
            cellCount: columns,
            cellSize: cellWidth,
            nonGridPixels: horizontalNonGridPixels
        )
        let targetHeight = safePixelDimension(
            cellCount: rows,
            cellSize: cellHeight,
            nonGridPixels: verticalNonGridPixels
        )

        mobileViewportCellLimit = (columns: max(1, columns), rows: max(1, rows))
        let baseWidth = lastUncappedPixelWidth > 0 ? lastUncappedPixelWidth : targetWidth
        let baseHeight = lastUncappedPixelHeight > 0 ? lastUncappedPixelHeight : targetHeight
        let appliedWidth = min(targetWidth, baseWidth)
        let appliedHeight = min(targetHeight, baseHeight)
        let sizeChanged = appliedWidth != lastPixelWidth || appliedHeight != lastPixelHeight
        updateMobileViewportBorder(
            appliedWidth: appliedWidth,
            appliedHeight: appliedHeight,
            baseWidth: baseWidth,
            baseHeight: baseHeight
        )

        #if DEBUG
        Self.sizeLog(
            "mobileViewportLimit surface=\(id.uuidString.prefix(8)) cells=\(columns)x\(rows) " +
            "capPx=\(targetWidth)x\(targetHeight) appliedPx=\(appliedWidth)x\(appliedHeight) " +
            "basePx=\(baseWidth)x\(baseHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else { return false }
        ghostty_surface_set_size(surface, appliedWidth, appliedHeight)
        lastPixelWidth = appliedWidth
        lastPixelHeight = appliedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    @discardableResult
    @MainActor
    func clearMobileViewportLimit(reason: String) -> Bool {
        mobileViewportCellLimit = nil
        hostedView.setMobileViewportBorder(size: nil, drawRight: false, drawBottom: false)

        let uncappedWidth = lastUncappedPixelWidth
        let uncappedHeight = lastUncappedPixelHeight
        guard let surface = liveSurfaceForGhosttyAccess(reason: "clearMobileViewportLimit"),
              uncappedWidth > 0,
              uncappedHeight > 0 else {
            return false
        }

        let sizeChanged = uncappedWidth != lastPixelWidth || uncappedHeight != lastPixelHeight

        #if DEBUG
        Self.sizeLog(
            "clearMobileViewportLimit surface=\(id.uuidString.prefix(8)) " +
            "uncappedPx=\(uncappedWidth)x\(uncappedHeight) prev=\(lastPixelWidth)x\(lastPixelHeight) " +
            "changed=\(sizeChanged ? 1 : 0) reason=\(reason)"
        )
        #endif

        guard sizeChanged else {
            ghostty_surface_refresh(surface)
            return false
        }
        ghostty_surface_set_size(surface, uncappedWidth, uncappedHeight)
        lastPixelWidth = uncappedWidth
        lastPixelHeight = uncappedHeight
        ghostty_surface_refresh(surface)
        return true
    }

    private func cappedByMobileViewportLimit(
        width: UInt32,
        height: UInt32,
        surface: ghostty_surface_t
    ) -> (width: UInt32, height: UInt32) {
        guard let mobileViewportPixelLimit = mobileViewportPixelLimit(for: surface) else {
            return (width, height)
        }
        return (
            width: min(width, mobileViewportPixelLimit.width),
            height: min(height, mobileViewportPixelLimit.height)
        )
    }

    private func mobileViewportPixelLimit(for surface: ghostty_surface_t) -> (width: UInt32, height: UInt32)? {
        guard let mobileViewportCellLimit else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        let currentColumns = max(1, Int(size.columns))
        let currentRows = max(1, Int(size.rows))
        let horizontalNonGridPixels = max(0, Int(size.width_px) - currentColumns * cellWidth)
        let verticalNonGridPixels = max(0, Int(size.height_px) - currentRows * cellHeight)
        return (
            width: safePixelDimension(
                cellCount: mobileViewportCellLimit.columns,
                cellSize: cellWidth,
                nonGridPixels: horizontalNonGridPixels
            ),
            height: safePixelDimension(
                cellCount: mobileViewportCellLimit.rows,
                cellSize: cellHeight,
                nonGridPixels: verticalNonGridPixels
            )
        )
    }

    private func safePixelDimension(cellCount: Int, cellSize: Int, nonGridPixels: Int) -> UInt32 {
        let clampedCellSize = max(1, cellSize)
        let clampedNonGridPixels = min(max(0, nonGridPixels), Int(UInt32.max) - 1)
        let maxCells = max(1, (Int(UInt32.max) - clampedNonGridPixels) / clampedCellSize)
        let clampedCellCount = min(max(1, cellCount), maxCells)
        return UInt32(clampedCellCount * clampedCellSize + clampedNonGridPixels)
    }

    private func updateMobileViewportBorder(
        appliedWidth: UInt32,
        appliedHeight: UInt32,
        baseWidth: UInt32,
        baseHeight: UInt32
    ) {
        let drawRightBorder = appliedWidth < baseWidth
        let drawBottomBorder = appliedHeight < baseHeight
        let borderScale = hostedView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        hostedView.setMobileViewportBorder(
            size: CGSize(
                width: CGFloat(appliedWidth) / max(1, borderScale),
                height: CGFloat(appliedHeight) / max(1, borderScale)
            ),
            drawRight: drawRightBorder,
            drawBottom: drawBottomBorder
        )
    }

    /// Force a full size recalculation and surface redraw.
    @MainActor
    func forceRefresh(reason: String = "unspecified") {
#if DEBUG
        let hasSurface = surface != nil
        let viewState: String
        if let view = attachedView {
            let inWindow = uiWindow != nil
            let bounds = view.bounds
            let metalOK = (view.layer as? CAMetalLayer) != nil
            viewState = "inWindow=\(inWindow) bounds=\(bounds) metalOK=\(metalOK) hasSurface=\(hasSurface)"
        } else {
            viewState = "NO_ATTACHED_VIEW hasSurface=\(hasSurface)"
        }
        cmuxDebugLog("forceRefresh: \(id) reason=\(reason) \(viewState)")
#endif
        guard let view = attachedView,
              let window = uiWindow,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return
        }
#if DEBUG
        recordDebugForceRefresh()
#endif
        // Re-read self.surface before each ghostty call to guard against the surface
        // being freed during wake-from-sleep geometry reconciliation (issue #432).
        // The surface can be invalidated between calls when AppKit layout triggers
        // view lifecycle changes (e.g., forceRefreshSurface → layout → deinit → free).

        // Reassert display id on topology churn (split close/reparent) before forcing a refresh.
        // This avoids a first-run stuck-vsync state where Ghostty believes vsync is active
        // but callbacks have not resumed for the current display.
        let displayID = (window.screen ?? NSScreen.main)?.displayID
#if DEBUG
        let accessReason = "forceRefresh.\(reason)"
#else
        let accessReason = "forceRefresh"
#endif
        guard let currentSurface = liveSurfaceForGhosttyAccess(reason: accessReason) else {
            return
        }
        if let displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(currentSurface, displayID)
        }

        view.forceRefreshSurface()
#if DEBUG
        let refreshReason = "forceRefresh.refresh.\(reason)"
#else
        let refreshReason = "forceRefresh.refresh"
#endif
        guard let surface = liveSurfaceForGhosttyAccess(reason: refreshReason) else {
            return
        }
        ghostty_surface_refresh(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    /// Keep `desiredFocusState` in sync when the hosted view's responder chain
    /// calls `ghostty_surface_set_focus` directly (bypassing `setFocus`).
    /// Without this, `createSurface` would replay a stale state on recreation.
    func recordExternalFocusState(_ focused: Bool) {
        desiredFocusState = focused
    }

    func setFocus(_ focused: Bool, force: Bool = false) {
        // Only send focus events when the state changes to avoid redundant
        // prompt redraws with zsh themes like Powerlevel10k.
        guard force || focused != desiredFocusState else { return }
        desiredFocusState = focused
        // Track desired state even before the C surface exists (e.g. during
        // layout restoration). createSurface syncs the state once created.
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)

        // If we focus a surface while it is being rapidly reparented (closing splits, etc),
        // Ghostty's CVDisplayLink can end up started before the display id is valid, leaving
        // hasVsync() true but with no callbacks ("stuck-vsync-no-frames"). Reasserting the
        // display id *after* focusing lets Ghostty restart the display link when needed.
        if focused {
            if let view = attachedView,
               let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    func prepareNextRuntimeInitialInput(_ input: String?) {
        let trimmedInput = input?.isEmpty == false ? input : nil
        nextRuntimeInitialInput = trimmedInput
    }

    @MainActor
    func prepareAgentHibernationResume(initialInput: String?) {
        runtimeSurfaceSuspendedForAgentHibernation = false
        prepareNextRuntimeInitialInput(initialInput)
    }

    func setOcclusion(_ visible: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func needsConfirmClose() -> Bool {
#if DEBUG
        if let needsConfirmCloseOverrideForTesting {
            return needsConfirmCloseOverrideForTesting
        }
#endif
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func noteClipboardReadCompleted() {
        clipboardReadGeneration += 1
        NotificationCenter.default.post(
            name: .terminalSurfaceDidCompleteClipboardRead,
            object: self
        )
    }

    @MainActor
    @discardableResult
    func sendText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return true }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return false }
            let queued = enqueuePendingSocketInput(.pasteText(data))
            if queued {
                recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
                requestBackgroundSurfaceStartIfNeeded()
            }
            return queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        writeTextData(data, to: liveSurface)
        return true
    }

    /// Deliver `text` through Ghostty's paste path (`ghostty_surface_text`), the
    /// same route a desktop clipboard paste or file drop takes.
    ///
    /// Unlike ``sendInputResult(_:)`` (which feeds bytes as typed text via
    /// `ghostty_surface_text_input`, with bracketed paste *disabled*), this wraps
    /// the bytes in a bracketed paste when the foreground program has enabled
    /// bracketed paste mode (DECSET 2004). That framing is what lets prompt UIs
    /// such as Claude Code recognize a pasted image file path and attach it as
    /// `[Image #N]` instead of inserting the literal path string. It mirrors the
    /// rich ``InputSendResult`` reporting of ``sendInputResult(_:)`` so callers
    /// keep precise queue/availability error mapping.
    @MainActor
    @discardableResult
    func sendTextResult(_ text: String) -> InputSendResult {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return .sent }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(.pasteText(data))
            if queued {
                recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
                requestBackgroundSurfaceStartIfNeeded()
            }
            return queued ? .queued : .inputQueueFull
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendText") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        writeTextData(data, to: liveSurface)
        return .sent
    }

    @MainActor
    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendKeyText") else {
            return false
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(liveSurface, keyEvent)
        }
    }

    @MainActor
    @discardableResult
    func sendNamedKey(_ keyName: String) -> NamedKeySendResult {
        guard let event = pendingKeyEvent(for: keyName) else { return .unknownKey }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            guard enqueuePendingSocketInput(.key(event)) else { return .inputQueueFull }
            recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
            requestBackgroundSurfaceStartIfNeeded()
            return .queued
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendNamedKey") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        sendKeyEvent(surface: liveSurface, keycode: event.keycode, mods: event.mods)
        return .sent
    }

    @MainActor
    func visibleText() -> String? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "visibleText") else { return nil }
        return Self.readText(surface: surface, pointTag: GHOSTTY_POINT_VIEWPORT)
    }

    @MainActor
    func mobileRenderGridFrame(
        stateSeq: UInt64,
        full: Bool = true,
        changedRows: Set<Int>? = nil,
        scrollbackLines: Int = 0
    ) -> (frame: MobileTerminalRenderGridFrame, rows: [String])? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "mobileRenderGrid") else { return nil }
        let surfaceID = id.uuidString
        let exported = surfaceID.withCString { ptr in
            ghostty_surface_render_grid_json(
                surface,
                ptr,
                UInt(surfaceID.utf8.count),
                stateSeq,
                UInt(max(0, scrollbackLines))
            )
        }
        defer { ghostty_string_free(exported) }
        guard let ptr = exported.ptr, exported.len > 0 else { return nil }

        let data = Data(bytes: ptr, count: Int(exported.len))
        guard let fullFrame = try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data) else {
            return nil
        }
        let frame: MobileTerminalRenderGridFrame
        if full, changedRows == nil {
            frame = fullFrame
        } else {
            let includedRows = changedRows ?? Set(0..<fullFrame.rows)
            guard let filtered = try? fullFrame.filteredRows(includedRows, full: full) else {
                return nil
            }
            frame = filtered
        }
        return (frame, frame.plainRows())
    }

    /// Send text with control characters (Return, Tab, etc.) delivered as key
    /// events so the shell processes them, while complete terminal control
    /// sequences are routed through Ghostty's PTY-output parser. Cold surfaces
    /// queue the same ordered events and flush them after runtime creation.
    @MainActor
    @discardableResult
    func sendInput(_ text: String) -> Bool {
        return sendInputResult(text).accepted
    }

    @MainActor
    @discardableResult
    func sendInputResult(_ text: String) -> InputSendResult {
        guard !text.isEmpty else { return .sent }
        guard surface != nil else {
            guard allowsRuntimeSurfaceCreation() else { return .surfaceUnavailable }
            let queued = enqueuePendingSocketInput(text)
            if queued {
                recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
                requestBackgroundSurfaceStartIfNeeded()
            }
            return queued ? .queued : .inputQueueFull
        }
        guard let liveSurface = liveSurfaceForSocketWrite(reason: "socket.sendInput") else {
            return .surfaceUnavailable
        }
        guard !ghostty_surface_process_exited(liveSurface) else { return .processExited }
        recordAgentHibernationTerminalInput(workspaceId: tabId, panelId: id)
        sendInput(text, to: liveSurface)
        return .sent
    }

    @MainActor
    private func sendInput(_ text: String, to surface: ghostty_surface_t) {
        for event in Self.parsedSocketInputEvents(for: text) {
            switch event {
            case .rawBytes(let data):
                writeInputTextData(data, to: surface)
            case .terminalBytes(let data):
                writeProcessOutputData(data, to: surface)
            case .key(let event):
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ text: String) -> Bool {
        let inputs = Self.parsedSocketInputEvents(for: text).compactMap { event -> PendingSocketInput? in
            switch event {
            case .rawBytes(let data):
                return data.isEmpty ? nil : .inputText(data)
            case .terminalBytes(let data):
                return data.isEmpty ? nil : .processOutput(data)
            case .key(let event):
                return .key(event)
            }
        }
        return enqueuePendingSocketInputs(inputs)
    }

    private static func parsedSocketInputEvents(for text: String) -> [ParsedSocketInput] {
        guard !text.isEmpty else { return [] }

        var events: [ParsedSocketInput] = []
        events.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)
        var previousWasCR = false
        let scalars = Array(text.unicodeScalars)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            for chunk in committedTextInputChunks(from: bufferedText) {
                events.append(.rawBytes(chunk))
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func appendKey(_ keycode: UInt32, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, label: String) {
            events.append(.key(PendingKeyEvent(
                keycode: keycode,
                mods: mods,
                label: label
            )))
        }

        func appendRawReturn() {
            events.append(.rawBytes(Data([0x0D])))
        }

        func appendTerminalBytes(length: Int, from start: Int) {
            guard length > 0 else { return }
            var sequence = ""
            for offset in start..<(start + length) {
                sequence.unicodeScalars.append(scalars[offset])
            }
            guard let data = sequence.data(using: .utf8), !data.isEmpty else { return }
            events.append(.terminalBytes(data))
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    appendRawReturn()
                }
                previousWasCR = false
                index += 1
            case 0x0D:
                flushBufferedText()
                appendRawReturn()
                previousWasCR = true
                index += 1
            case 0x09:
                flushBufferedText()
                appendKey(UInt32(kVK_Tab), label: "tab")
                previousWasCR = false
                index += 1
            case 0x1B:
                // A bare ESC is the Escape key. But a full CSI/SS3 navigation
                // sequence arriving as raw input (the iOS on-screen arrows send
                // ESC[B, etc.) must stay one key press, or the terminal receives
                // Escape followed by literal "[B". Re-issue recognized sequences
                // as key events so libghostty encodes them for the surface's
                // current cursor-key mode, exactly like a hardware arrow press.
                if let nav = navigationEscapeKey(scalars, from: index) {
                    flushBufferedText()
                    appendKey(nav.keycode, mods: nav.mods, label: nav.label)
                    index += nav.length
                } else if let length = terminalControlSequenceLength(scalars, from: index) {
                    flushBufferedText()
                    appendTerminalBytes(length: length, from: index)
                    index += length
                } else {
                    flushBufferedText()
                    appendKey(UInt32(kVK_Escape), label: "escape")
                    index += 1
                }
                previousWasCR = false
            case 0x08, 0x7F:
                flushBufferedText()
                appendKey(UInt32(kVK_Delete), label: "backspace")
                previousWasCR = false
                index += 1
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
                index += 1
            }
        }
        flushBufferedText()
        return events
    }

    /// Returns the byte-like scalar length for a complete terminal string control sequence.
    private static func terminalControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count, scalars[start].value == 0x1B else { return nil }

        switch scalars[start + 1].value {
        case 0x5D: // OSC: ESC ] ... (BEL | ST)
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: true)
        case 0x50, 0x5E, 0x5F: // DCS / PM / APC: ESC P/^/_ ... ST
            return stringControlSequenceLength(scalars, from: start, terminatesWithBEL: false)
        default:
            return nil
        }
    }

    /// Finds the terminator for ESC-prefixed string controls without accepting partial sequences.
    private static func stringControlSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int,
        terminatesWithBEL: Bool
    ) -> Int? {
        var index = start + 2
        while index < scalars.count {
            let value = scalars[index].value
            if terminatesWithBEL, value == 0x07 {
                return index - start + 1
            }
            if value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index - start + 2
            }
            index += 1
        }
        return nil
    }

    /// Match a CSI (`ESC [ …`) or SS3 (`ESC O …`) cursor/navigation escape
    /// sequence beginning at `start` (which points at the ESC, 0x1B). Returns
    /// the equivalent macOS key code and how many scalars the sequence consumed,
    /// or nil for a bare ESC or an unrecognized sequence (which stays the
    /// Escape key). Only unmodified navigation keys are mapped; the surface
    /// re-encodes them for its current DECCKM cursor-key mode.
    private static func navigationEscapeKey(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> (keycode: UInt32, mods: ghostty_input_mods_e, label: String, length: Int)? {
        guard start + 1 < scalars.count else { return nil }
        let next = scalars[start + 1].value
        // Meta+Backspace: the iOS app sends ESC 0x7F (or ESC 0x08) for
        // option-delete-word. Re-issue as Backspace with the Option modifier so
        // libghostty encodes the meta-backspace for the surface, instead of the
        // bare-ESC path splitting it into Escape + a plain backspace.
        if next == 0x7F || next == 0x08 {
            return (UInt32(kVK_Delete), GHOSTTY_MODS_ALT, "alt-backspace", 2)
        }
        // CSI (ESC[) / SS3 (ESCO) cursor + navigation sequences.
        guard next == 0x5B || next == 0x4F, start + 2 < scalars.count else { return nil }
        let final = scalars[start + 2].value
        switch final {
        case 0x41: return (UInt32(kVK_UpArrow), GHOSTTY_MODS_NONE, "up", 3)        // A
        case 0x42: return (UInt32(kVK_DownArrow), GHOSTTY_MODS_NONE, "down", 3)    // B
        case 0x43: return (UInt32(kVK_RightArrow), GHOSTTY_MODS_NONE, "right", 3)  // C
        case 0x44: return (UInt32(kVK_LeftArrow), GHOSTTY_MODS_NONE, "left", 3)    // D
        case 0x48: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 3)         // H
        case 0x46: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 3)           // F
        default:
            break
        }
        // CSI tilde sequences: ESC [ N ~
        if next == 0x5B, start + 3 < scalars.count, scalars[start + 3].value == 0x7E {
            switch final {
            case 0x31: return (UInt32(kVK_Home), GHOSTTY_MODS_NONE, "home", 4)               // 1~
            case 0x33: return (UInt32(kVK_ForwardDelete), GHOSTTY_MODS_NONE, "forwardDelete", 4) // 3~
            case 0x34: return (UInt32(kVK_End), GHOSTTY_MODS_NONE, "end", 4)                 // 4~
            case 0x35: return (UInt32(kVK_PageUp), GHOSTTY_MODS_NONE, "pageUp", 4)           // 5~
            case 0x36: return (UInt32(kVK_PageDown), GHOSTTY_MODS_NONE, "pageDown", 4)       // 6~
            default:
                break
            }
        }
        return nil
    }

    private static func committedTextInputChunks(from text: String) -> [Data] {
        guard !text.isEmpty else { return [] }

        var chunks: [Data] = []
        chunks.reserveCapacity(max(1, (text.utf8.count / committedTextInputChunkByteLimit) + 1))
        var chunk = Data()
        chunk.reserveCapacity(committedTextInputChunkByteLimit)

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            chunks.append(chunk)
            chunk.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8
            if !chunk.isEmpty, chunk.count + scalarBytes.count > committedTextInputChunkByteLimit {
                flushChunk()
            }
            chunk.append(contentsOf: scalarBytes)
        }
        flushChunk()
        return chunks
    }

    // Canonical key text for synthetic key events sent from the mobile/socket
    // input path (see `sendKeyEvent`). The desktop `keyDown` handler fills
    // `ghostty_input_key_s.text` from `charactersIgnoringModifiers`; libghostty
    // needs that text to encode control keys whose byte is otherwise filtered by
    // the raw-text input path. Mobile builds the event from a bare keycode, so we
    // reproduce the same canonical text here, keyed purely off the keycode.
    //
    // Only Backspace/Delete and Tab need this: their physical macOS keys carry
    // the DEL (0x7F) and TAB (0x09) characters in `charactersIgnoringModifiers`.
    // The text is independent of modifiers (Option-Backspace still reports DEL),
    // so this intentionally ignores `mods`. Pure function keys (arrows, Home,
    // End, page navigation) carry no characters and correctly encode from the
    // keycode alone, so they return nil.
    private static func canonicalKeyText(keycode: UInt32) -> String? {
        switch keycode {
        case UInt32(kVK_Delete):
            return "\u{7F}"
        case UInt32(kVK_Tab):
            return "\t"
        default:
            return nil
        }
    }

    private func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false

        let canonicalText = Self.canonicalKeyText(keycode: keycode)
        keyEvent.unshifted_codepoint = canonicalText?.unicodeScalars.first?.value ?? 0

        let handled: Bool
        if let canonicalText {
            // Mirror the desktop `keyDown` path's C-string lifetime: the text
            // pointer must stay valid only for the `ghostty_surface_key` call.
            handled = canonicalText.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            handled = ghostty_surface_key(surface, keyEvent)
        }

#if DEBUG
        cmuxDebugLog(
            "surface.socket_input.key surface=\(id.uuidString.prefix(8)) " +
            "keycode=\(keycode) mods=\(mods.rawValue) " +
            "codepoint=0x\(String(keyEvent.unshifted_codepoint, radix: 16)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
    }

    @MainActor
    private func liveSurfaceForSocketWrite(reason: String) -> ghostty_surface_t? {
        return liveSurfaceForGhosttyAccess(reason: reason)
    }

    // Socket/API operations are an explicit runtime demand: they must be able to
    // start a terminal in a background workspace without selecting that workspace.
    // When there is no real window yet, bootstrap Ghostty in a hidden window and
    // reconcile display/window state when the terminal is later presented.
    func requestBackgroundSurfaceStartIfNeeded() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        guard allowsRuntimeSurfaceCreation() else { return }
        guard surface == nil else { return }
        guard !backgroundSurfaceStartQueued else { return }
        backgroundSurfaceStartQueued = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.backgroundSurfaceStartQueued = false
                guard self.allowsRuntimeSurfaceCreation() else { return }
                guard self.surface == nil else { return }
            #if DEBUG
                let startedAt = ProcessInfo.processInfo.systemUptime
            #endif
                if let view = self.attachedView, view.window != nil {
                    self.createSurface(for: view)
                } else {
                    self.scheduleHeadlessRuntimeStartIfNeeded(reason: "background-input")
                }
            #if DEBUG
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
                let view = self.attachedView ?? self.surfaceView
                cmuxDebugLog(
                    "surface.background_start surface=\(self.id.uuidString.prefix(8)) inWindow=\(view.window != nil ? 1 : 0) ready=\(self.surface != nil ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs))"
                )
            #endif
            }
        }
    }

    private func writeTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private func writeInputTextData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    /// Sends bytes through Ghostty's PTY-output parser so OSC commands affect terminal state.
    private func writeProcessOutputData(_ data: Data, to surface: ghostty_surface_t) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    private static func readText(
        surface: ghostty_surface_t,
        pointTag: ghostty_point_tag_e
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    private func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    private func keycodeForNamedKey(_ name: String) -> UInt32? {
        switch name {
        case "enter", "return": return UInt32(kVK_Return)
        case "tab": return UInt32(kVK_Tab)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "backspace": return UInt32(kVK_Delete)
        case "delete": return UInt32(kVK_ForwardDelete)
        case "space": return UInt32(kVK_Space)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        default: return nil
        }
    }

    private func pendingKeyEvent(for keyName: String) -> PendingKeyEvent? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-d", "ctrl+d", "eof":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-f", "ctrl+f":
            // Force-stop chord for embedded TUIs (e.g. Claude Code's "Ctrl-F twice").
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_F), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return PendingKeyEvent(keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL, label: normalized)
        case "enter", "return":
            return PendingKeyEvent(keycode: UInt32(kVK_Return), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "tab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "escape", "esc":
            return PendingKeyEvent(keycode: UInt32(kVK_Escape), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "backspace":
            return PendingKeyEvent(keycode: UInt32(kVK_Delete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "up", "arrow_up", "arrowup":
            return PendingKeyEvent(keycode: UInt32(kVK_UpArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "down", "arrow_down", "arrowdown":
            return PendingKeyEvent(keycode: UInt32(kVK_DownArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "left", "arrow_left", "arrowleft":
            return PendingKeyEvent(keycode: UInt32(kVK_LeftArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "right", "arrow_right", "arrowright":
            return PendingKeyEvent(keycode: UInt32(kVK_RightArrow), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "shift+tab", "shift-tab", "backtab":
            return PendingKeyEvent(keycode: UInt32(kVK_Tab), mods: GHOSTTY_MODS_SHIFT, label: normalized)
        case "home":
            return PendingKeyEvent(keycode: UInt32(kVK_Home), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "end":
            return PendingKeyEvent(keycode: UInt32(kVK_End), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "delete", "del", "forward_delete":
            return PendingKeyEvent(keycode: UInt32(kVK_ForwardDelete), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pageup", "page_up":
            return PendingKeyEvent(keycode: UInt32(kVK_PageUp), mods: GHOSTTY_MODS_NONE, label: normalized)
        case "pagedown", "page_down":
            return PendingKeyEvent(keycode: UInt32(kVK_PageDown), mods: GHOSTTY_MODS_NONE, label: normalized)
        default:
            let parts = normalized
                .split(separator: "+")
                .flatMap { $0.split(separator: "-") }
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let baseKey = parts.last else { return nil }

            if parts.count == 1 {
                if let keycode = keycodeForNamedKey(baseKey) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                if baseKey.count == 1,
                   let char = baseKey.first,
                   let keycode = keycodeForLetter(char) {
                    return PendingKeyEvent(keycode: keycode, mods: GHOSTTY_MODS_NONE, label: normalized)
                }
                return nil
            }

            var mods = GHOSTTY_MODS_NONE
            for mod in parts.dropLast() {
                switch mod {
                case "ctrl", "control":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
                case "shift":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
                case "alt", "opt", "option":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_ALT.rawValue)
                case "cmd", "command", "super":
                    mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_SUPER.rawValue)
                default:
                    return nil
                }
            }

            if let keycode = keycodeForNamedKey(baseKey) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            if baseKey.count == 1,
               let char = baseKey.first,
               let keycode = keycodeForLetter(char) {
                return PendingKeyEvent(keycode: keycode, mods: mods, label: normalized)
            }
            return nil
        }
    }

    @MainActor
    private func enqueuePendingSocketInput(_ input: PendingSocketInput) -> Bool {
        enqueuePendingSocketInputs([input])
    }

    @MainActor
    private func enqueuePendingSocketInputs(_ inputs: [PendingSocketInput]) -> Bool {
        let incomingBytes = inputs.reduce(0) { $0 + $1.estimatedBytes }
        guard incomingBytes > 0 else { return true }

        guard incomingBytes <= maxPendingSocketInputBytes,
              pendingSocketInputBytes + incomingBytes <= maxPendingSocketInputBytes else {
#if DEBUG
            cmuxDebugLog(
                "surface.socket_input.reject surface=\(id.uuidString.prefix(8)) " +
                "items=\(inputs.count) incomingBytes=\(incomingBytes) pendingBytes=\(pendingSocketInputBytes)"
            )
#endif
            return false
        }

        pendingSocketInputQueue.append(contentsOf: inputs)
        pendingSocketInputBytes += incomingBytes
#if DEBUG
        let pendingKeys = pendingSocketInputQueue.reduce(into: 0) { count, item in
            if case .key = item {
                count += 1
            }
        }
        cmuxDebugLog(
            "surface.socket_input.queue surface=\(id.uuidString.prefix(8)) items=\(pendingSocketInputQueue.count) " +
            "keys=\(pendingKeys) bytes=\(pendingSocketInputBytes)"
        )
#endif
        return true
    }

    @MainActor
    private func flushPendingSocketInputIfNeeded() {
        guard let surface = liveSurfaceForSocketWrite(reason: "socket.flushPendingInput") else { return }
        let queued = pendingSocketInputQueue
        let queuedBytes = pendingSocketInputBytes
        pendingSocketInputQueue.removeAll(keepingCapacity: false)
        pendingSocketInputBytes = 0
        guard !queued.isEmpty else { return }

        var queuedKeys = 0
        for item in queued {
            switch item {
            case .pasteText(let chunk):
                writeTextData(chunk, to: surface)
            case .inputText(let chunk):
                writeInputTextData(chunk, to: surface)
            case .processOutput(let chunk):
                writeProcessOutputData(chunk, to: surface)
            case .key(let event):
                queuedKeys += 1
                sendKeyEvent(surface: surface, keycode: event.keycode, mods: event.mods)
            }
        }
#if DEBUG
        cmuxDebugLog(
            "surface.socket_input.flush surface=\(id.uuidString.prefix(8)) items=\(queued.count) " +
            "keys=\(queuedKeys) bytes=\(queuedBytes)"
        )
#endif
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        let handled = surfaceView.toggleKeyboardCopyMode()
        if handled {
            setKeyboardCopyModeActive(surfaceView.isKeyboardCopyModeActive)
        }
        return handled
    }

    func setKeyboardCopyModeActive(_ active: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setKeyboardCopyModeActive(active)
            }
            return
        }

        if keyboardCopyModeActive != active {
            keyboardCopyModeActive = active
        }
        hostedView.syncKeyStateIndicator(text: surfaceView.currentKeyStateIndicatorText)
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

#if DEBUG
    @MainActor
    func setNeedsConfirmCloseOverrideForTesting(_ value: Bool?) {
        needsConfirmCloseOverrideForTesting = value
    }

    @MainActor
    func debugRuntimeSurfaceCreateAttemptCountForTesting() -> Int {
        runtimeSurfaceCreateAttemptCountForTesting
    }

    @MainActor
    func debugBackgroundSurfaceStartQueuedForTesting() -> Bool {
        backgroundSurfaceStartQueued
    }

    @MainActor
    func debugHasHeadlessStartupWindowForTesting() -> Bool {
        headlessStartupWindow != nil
    }

    @MainActor
    func debugPendingSocketInputForTesting() -> (
        items: Int,
        bytes: Int,
        keyEvents: Int,
        pasteTextItems: Int,
        inputTextItems: Int,
        processOutputItems: Int
    ) {
        let counts = pendingSocketInputQueue.reduce(
            into: (keyEvents: 0, pasteTextItems: 0, inputTextItems: 0, processOutputItems: 0)
        ) { counts, item in
            switch item {
            case .key:
                counts.keyEvents += 1
            case .pasteText:
                counts.pasteTextItems += 1
            case .inputText:
                counts.inputTextItems += 1
            case .processOutput:
                counts.processOutputItems += 1
            }
        }
        return (
            pendingSocketInputQueue.count,
            pendingSocketInputBytes,
            counts.keyEvents,
            counts.pasteTextItems,
            counts.inputTextItems,
            counts.processOutputItems
        )
    }

    /// Test-only helper to deterministically simulate a released runtime surface.
    @MainActor
    func releaseSurfaceForTesting() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        surface = nil
        ghostty_surface_free(surfaceToFree)
        callbackContext?.release()
    }

    /// Test-only helper to simulate a stale Swift wrapper whose native surface
    /// was already freed out-of-band.
    @MainActor
    func replaceSurfaceWithFreedPointerForTesting() {
        guard !runtimeSurfaceFreedOutOfBandForTesting else { return }

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        guard let surfaceToFree = surface else {
            callbackContext?.release()
            return
        }

        TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        ghostty_surface_free(surfaceToFree)
        runtimeSurfaceFreedOutOfBandForTesting = true
        callbackContext?.release()
    }

    @MainActor
    func installRuntimeSurfaceForTesting(_ runtimeSurface: ghostty_surface_t) {
        surface = runtimeSurface
        portalLifecycleState = .live
        runtimeSurfaceFreedOutOfBandForTesting = false
    }
#endif

    deinit {
        claudeCommandShimInstallTask?.cancel()
        TerminalSurfaceRegistry.shared.unregister(self)
        markPortalLifecycleClosed(reason: "deinit")
        closeHeadlessStartupWindowIfNeeded()

        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        // Mirror teardownSurface/suspend: release the retained mobile byte-tee
        // userdata and drop the per-surface tee state keyed by this surface id,
        // BEFORE freeing the surface. A terminal closed via deinit (not explicit
        // teardown) would otherwise leak the tee userdata and leave stale mobile
        // replay buffers keyed by the old id. If teardown already ran, it nil'd
        // mobileByteTeeContext, so teeContext is nil here and ?.release() no-ops.
        let teeContext = mobileByteTeeContext
        mobileByteTeeContext = nil
        // `dropSurface` is @MainActor but `deinit` is nonisolated, so hop to the
        // main actor with the surface id captured by value (no self capture).
        // Dropping by id only clears the registry/replay state; releasing
        // `teeContext` on each exit path frees the userdata independently.
        let teeSurfaceID = id
        Task { @MainActor in MobileTerminalByteTee.shared.dropSurface(surfaceID: teeSurfaceID) }

        // Nil out the surface pointer so any in-flight closures (e.g. geometry
        // reconcile dispatched via DispatchQueue.main.async) that read self.surface
        // before this object is fully deallocated will see nil and bail out,
        // rather than passing a freed pointer to ghostty_surface_refresh (#432).
        let surfaceToFree = surface
        if let surfaceToFree {
            TerminalSurfaceRegistry.shared.unregisterRuntimeSurface(surfaceToFree, ownerId: id)
        }
        surface = nil

        guard let surfaceToFree else {
#if DEBUG
            cmuxDebugLog(
                "surface.lifecycle.deinit.skip surface=\(id.uuidString.prefix(5)) " +
                "workspace=\(tabId.uuidString.prefix(5)) reason=noRuntimeSurface"
            )
#endif
            callbackContext?.release()
            teeContext?.release()
            return
        }

#if DEBUG
        if runtimeSurfaceFreedOutOfBandForTesting {
            runtimeSurfaceFreedOutOfBandForTesting = false
            callbackContext?.release()
            teeContext?.release()
            return
        }
#endif

#if DEBUG
        cmuxDebugLog(
            "surface.lifecycle.deinit.begin surface=\(id.uuidString.prefix(5)) " +
            "workspace=\(tabId.uuidString.prefix(5)) hasAttachedView=\(attachedView != nil ? 1 : 0) " +
            "hostedInWindow=\(hostedView.window != nil ? 1 : 0)"
        )
#endif

        // Keep teardown asynchronous to avoid re-entrant close/deinit loops, but retain
        // callback userdata until surface free completes so callbacks never dereference
        // a deallocated view pointer.
        enqueueTerminalSurfaceRuntimeTeardown(
            id: id,
            workspaceId: tabId,
            reason: "deinit",
            surface: surfaceToFree,
            callbackContext: callbackContext
        )
        // The teardown coordinator releases callbackContext; teeContext is not
        // transported through the request, so release it here (mirrors teardownSurface).
        teeContext?.release()
    }
}

extension TerminalSurface {
    @MainActor
    func owningWorkspace() -> Workspace? {
        AppDelegate.shared?.workspaceFor(tabId: tabId)
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxFocusDebug")
    }()
    internal enum DropPlan: Equatable {
        case insertText(String)
        case uploadFiles([URL])
        case reject
    }

    private static let dropTypes: Set<NSPasteboard.PasteboardType> = PasteboardFileURLReader.fileURLPasteboardTypes.union([
        .string,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier)
    ])
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")

    private enum WordPathResolutionSource: String {
        case quicklook
        case snapshot
    }

    private struct WordPathResolution {
        let path: String
        let source: WordPathResolutionSource
        let rawToken: String
    }

    private func makeWordPathResolution(
        path: String,
        source: WordPathResolutionSource,
        rawToken: String
    ) -> WordPathResolution {
        WordPathResolution(
            path: path,
            source: source,
            rawToken: rawToken
        )
    }

    fileprivate static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        AppDelegate.shared?.focusLog.append(message)
        #if DEBUG
        NSLog("[FOCUSDBG] %@", message)
        #endif
    }

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    private var _pendingScrollbar: GhosttyScrollbar?
    private var _scrollbarFlushScheduled = false
    private let _scrollbarLock = NSLock()
    private var _renderedFrameFlushScheduled = false
    private let _renderedFrameLock = NSLock()
    var cellSize: CGSize = .zero
    private var lastKnownMousePointInView: NSPoint?

    static func retainRenderedFrameNotifications() -> () -> Void {
        GhosttyRenderedFrameNotificationDemand.retain()
    }

    /// Coalesce high-frequency scrollbar updates into a single main-thread
    /// dispatch.  The action callback (which may fire thousands of times per
    /// second during bulk output like `seq 1 100000`) stores the latest value
    /// and schedules exactly one async flush.
    func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        _scrollbarLock.lock()
        defer { _scrollbarLock.unlock() }
        // Store the latest value (always overwrites — only the newest matters).
        _pendingScrollbar = newValue
        let needsSchedule = !_scrollbarFlushScheduled
        if needsSchedule { _scrollbarFlushScheduled = true }

        // If a flush is already scheduled, skip the dispatch — the scheduled
        // block will pick up the latest value.
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingScrollbar()
        }
    }

    private func flushPendingScrollbar() {
        _scrollbarLock.lock()
        _scrollbarFlushScheduled = false
        let pending = _pendingScrollbar
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard let pending else { return }
        scrollbar = pending
        finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: pending)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: [GhosttyNotificationKey.scrollbar: pending]
        )
    }

    private func flushPendingScrollbarIfAvailable() -> Bool {
        _scrollbarLock.lock()
        let hasPending = _pendingScrollbar != nil
        _scrollbarLock.unlock()

        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

    func enqueueRenderedFrameUpdate() {
        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }

        _renderedFrameLock.lock()
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }
        _renderedFrameLock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameLock.lock()
        _renderedFrameFlushScheduled = false
        _renderedFrameLock.unlock()

        guard GhosttyRenderedFrameNotificationDemand.isActive else { return }
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: self
        )
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var lastLoggedSurfaceBackgroundSignature: String?
    private var lastLoggedWindowBackgroundSignature: String?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    fileprivate private(set) var keyboardCopyModeActive = false
    private var wordPathHoverActive = false
    private var keyboardCopyModeConsumedKeyUps: Set<UInt16> = []
    private var imeConsumedKeyUps: Set<UInt16> = []
    private var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    private var keyboardCopyModeCursor: TerminalKeyboardCopyModeCursor?
    private var keyboardCopyModePendingViewportJumpSync = false
    private var keyboardCopyModePendingViewportJumpScrollbarOffset: UInt64?
    private var keyboardCopyModePendingViewportJumpGeneration = 0
    private var keyboardCopyModePendingViewportJumpFallbackLineDelta: Int?
    private var keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because non-visual copy mode keeps
    /// the cursor in AppKit overlay state until visual selection starts.
    private var keyboardCopyModeVisualActive = false
    private let keyboardCopyModeCursorOverlayView = GhosttyFlashOverlayView(frame: .zero)
    fileprivate var isKeyboardCopyModeActive: Bool { keyboardCopyModeActive }
    fileprivate var currentKeyStateIndicatorText: String? {
        if let name = keyTables.last {
            return terminalKeyTableIndicatorText(name)
        }

        if keyboardCopyModeActive {
            return terminalKeyboardCopyModeIndicatorText
        }

        return nil
    }
#if DEBUG
    private static let keyLatencyProbeEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    @MainActor static var debugGhosttySurfaceKeyEventObserver: ((ghostty_input_key_s) -> Void)?
    @MainActor static var debugTextInputEventHandler: ((GhosttyNSView, NSEvent) -> Bool)?
#endif
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var lastScrollEventTime: CFTimeInterval = 0
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
    private var deferredSurfaceSizeRetryQueued = false
    private var lastDrawableSize: CGSize = .zero
    private var isFindEscapeSuppressionArmed = false
    private var hasPendingLeftMouseRelease = false
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif

    private var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

    // Visibility is used for focus gating. Explicit portal visibility transitions
    // also drive Ghostty occlusion so hidden workspace/split surfaces pause and
    // queue a redraw when they become visible again.
    fileprivate var isVisibleInUI: Bool { visibleInUI }
    fileprivate func setVisibleInUI(_ visible: Bool) {
        visibleInUI = visible
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = GhosttyMetalLayer()
        metalLayer.setSurfaceView(self)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        // framebufferOnly=false lets the macOS compositor read the drawable
        // when blending translucent or blurred window layers.  This matches
        // standalone Ghostty's SurfaceView and is required for background-opacity
        // and background-blur to render correctly.
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        // GhosttyMetalLayer provides render stats and opt-in frame notifications for
        // input sequencing that needs to wait for terminal redraws.
        wantsLayer = true
        layer?.masksToBounds = true
        setupKeyboardCopyModeCursorOverlay()
        installEventMonitor()
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    private func setupKeyboardCopyModeCursorOverlay() {
        keyboardCopyModeCursorOverlayView.wantsLayer = true
        keyboardCopyModeCursorOverlayView.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.45)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.70)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderWidth = 1
        keyboardCopyModeCursorOverlayView.isHidden = true
        addSubview(keyboardCopyModeCursorOverlayView, positioned: .above, relativeTo: nil)
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let usesBonsplitPaneBackdrop = Workspace.usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: backgroundColor,
            defaultBackgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: usesBonsplitPaneBackdrop
        )
        let color = fillPlan.hostLayerColor
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // GhosttySurfaceScrollView owns the panel background fill. Keeping this layer clear
            // avoids stacking multiple identical translucent backgrounds (which looks opaque).
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(
            color,
            clearsSharedWindowBackdrop: fillPlan.clearsSharedWindowBackdrop
        )
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(fillPlan.usesHostLayerFill ? color.hexString() : "transparent-host"):\(String(format: "%.3f", color.alphaComponent)):\(fillPlan.logBackdropLabel)"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                GhosttyApp.shared.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(fillPlan.logSource(hasSurfaceOverride: hasOverride)) override=\(overrideHex) default=\(defaultHex) sharedWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) bonsplitPaneBackdrop=\(usesBonsplitPaneBackdrop ? 1 : 0) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    // Theme/background application is window-local. During cross-window workspace
    // switches (e.g. jump-to-unread), the global active tab manager can lag behind.
    // Prefer the owning window's selected workspace when available.
    static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        let appDelegate = AppDelegate.shared
        let owningManager = tabId.flatMap { appDelegate?.tabManagerFor(tabId: $0) }
        let owningSelectedTabId = owningManager?.selectedTabId
        let activeSelectedTabId = owningManager == nil ? appDelegate?.tabManager?.selectedTabId : nil
        guard Self.shouldApplyWindowBackground(
            surfaceTabId: tabId,
            owningManagerExists: owningManager != nil,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ) else {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        let snapshot = WindowAppearanceSnapshot
            .currentFromUserDefaults(app: GhosttyApp.shared)
            .replacingTerminalBackgroundColor(backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(plan.hostingPhase.rawValue):\(color.hexString()):\(String(format: "%.3f", color.alphaComponent)):\(GhosttyApp.shared.defaultBackgroundBlur)"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                let source = hasOverride ? "surfaceOverride" : "defaultBackground"
                GhosttyApp.shared.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(source) override=\(overrideHex) default=\(defaultHex) phase=\(plan.hostingPhase.rawValue) transparent=\(plan.usesTransparentWindow) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent)) blur=\(GhosttyApp.shared.defaultBackgroundBlur)"
                )
            }
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        let isSameSurface = terminalSurface === surface
        let isAlreadyAttached = surface.isAttached(to: self)
        if !isSameSurface {
            appliedColorScheme = nil
        }
        terminalSurface = surface
        tabId = surface.tabId
        if !isAlreadyAttached {
            surface.attachToView(self)
        } else {
            surface.reconcileAttachedWindowIfNeeded(for: self)
        }
        surface.setKeyboardCopyModeActive(keyboardCopyModeActive)
        if !isAlreadyAttached {
            updateSurfaceSize()
        }
        applySurfaceBackground()
        applySurfaceColorScheme(force: !isSameSurface || !isAlreadyAttached)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        // Balance the cursor stack if the view is removed while hover is active
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        cmuxDebugLog(
            "surface.view.windowMove surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) bounds=\(String(format: "%.1fx%.1f", Double(bounds.width), Double(bounds.height))) " +
            "pending=\(String(format: "%.1fx%.1f", Double(pendingSurfaceSize?.width ?? 0), Double(pendingSurfaceSize?.height ?? 0)))"
        )
#endif
        guard let window else { return }

        // Reconcile the already-started runtime with the real window backing context.
        terminalSurface?.attachToView(self)
        if let terminalSurface {
            NotificationCenter.default.post(
                name: .terminalSurfaceHostedViewDidMoveToWindow,
                object: terminalSurface,
                userInfo: [
                    "surfaceId": terminalSurface.id,
                    "workspaceId": terminalSurface.tabId
                ]
            )
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.windowDidChangeScreen(notification)
        }

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Recompute from current bounds after layout. Pending size is only a fallback
        // when we don't have usable bounds (e.g. detached/off-window transitions).
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidMoveToWindow"
        )
        applyWindowBackgroundIfActive()
        invalidateTextInputCoordinates()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if GhosttyApp.shared.backgroundLogEnabled {
            let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            GhosttyApp.shared.logBackground(
                "surface appearance changed tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil")"
            )
        }
        applySurfaceColorScheme()
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidChangeEffectiveAppearance"
        )
    }

    fileprivate func updateOcclusionState() {
        // Intentionally no-op: we don't drive libghostty occlusion from AppKit occlusion state.
        // This avoids transient clears during reparenting and keeps rendering logic minimal.
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
        invalidateTextInputCoordinates()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
        syncKeyboardCopyModeCursorOverlay()
        invalidateTextInputCoordinates()
    }

    override var isOpaque: Bool { false }

    private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }

        let currentBounds = bounds.size
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }

        if let pending = pendingSurfaceSize,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }

        return currentBounds
    }

    private static func hasTabDragPasteboardTypes() -> Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(tabTransferPasteboardType) || types.contains(sidebarTabReorderPasteboardType)
    }

    private static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func shouldDeferSurfaceResizeForActiveDrag() -> Bool {
        // The drag pasteboard can retain tab-transfer UTIs briefly after a split command
        // or other layout churn. Only defer terminal resizes while an actual drag event
        // is in flight; otherwise pre-existing panes can stay stuck at their old size.
        // Interactive geometry resize already has an explicit fast path for sidebar and
        // split-divider drags. Do not let stale drag-pasteboard state suppress those updates.
        if TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive {
            return false
        }
        guard hasTabDragPasteboardTypes() else { return false }
        return isDragResizeEvent(NSApp.currentEvent?.type)
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        if inLiveResize || window?.inLiveResize == true {
            return nil
        }
        return Self.shouldDeferSurfaceResizeForActiveDrag() ? "tabDrag" : nil
    }

    private func scheduleDeferredSurfaceSizeRetryIfNeeded() {
        guard window != nil else { return }
        guard !deferredSurfaceSizeRetryQueued else { return }
        deferredSurfaceSizeRetryQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredSurfaceSizeRetryQueued = false
            _ = self.updateSurfaceSize()
        }
    }

    @discardableResult
    private func updateSurfaceSize(size: CGSize? = nil) -> Bool {
        guard let terminalSurface = terminalSurface else { return false }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
#if DEBUG
            let signature = "nonPositive-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=nonPositive size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
        pendingSurfaceSize = size
        if let deferralReason = activeSurfaceResizeDeferralReason() {
            scheduleDeferredSurfaceSizeRetryIfNeeded()
#if DEBUG
            let signature = "\(deferralReason)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(deferralReason) " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        guard let window else {
#if DEBUG
            let signature = "noWindow-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=noWindow " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        // First principles: derive pixel size from AppKit's backing conversion for the current
        // window/screen. Avoid updating Ghostty while detached from a window.
        let backingSize = convertToBacking(NSRect(origin: .zero, size: size)).size
        guard backingSize.width > 0, backingSize.height > 0 else {
#if DEBUG
            let signature = "zeroBacking-\(Int(backingSize.width))x\(Int(backingSize.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=zeroBacking " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
#if DEBUG
        if lastSizeSkipSignature != nil {
            cmuxDebugLog(
                "surface.size.resume surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
            )
            lastSizeSkipSignature = nil
        }
#endif
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
        var didChange = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer, !nearlyEqual(layer.contentsScale, layerScale) {
            didChange = true
        }
        layer?.contentsScale = layerScale
        layer?.masksToBounds = true
        if let metalLayer = layer as? CAMetalLayer {
            if drawablePixelSize != lastDrawableSize || metalLayer.drawableSize != drawablePixelSize {
                if metalLayer.drawableSize != drawablePixelSize {
                    didChange = true
                }
                if metalLayer.drawableSize != drawablePixelSize {
                    metalLayer.drawableSize = drawablePixelSize
                }
                lastDrawableSize = drawablePixelSize
            }
        }
        CATransaction.commit()

        let surfaceSizeChanged = terminalSurface.updateSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize
        )
        return didChange || surfaceSizeChanged
    }

    @discardableResult
    fileprivate func pushTargetSurfaceSize(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }

#if DEBUG
    fileprivate func debugPendingSurfaceSize() -> CGSize? {
        pendingSurfaceSize
    }
#endif

    /// Force a full size reconciliation for the current bounds.
    /// Keep the drawable-size cache intact so redundant refresh paths do not
    /// reallocate Metal drawables when the pixel size is unchanged.
    @discardableResult
    func forceRefreshSurface() -> Bool {
        updateSurfaceSize()
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        let backing = convertToBacking(NSRect(origin: .zero, size: pointsSize)).size
        if backing.width > 0, backing.height > 0 {
            return backing
        }
        let scale = max(1.0, window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    fileprivate func applySurfaceColorScheme(
        force: Bool = false,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let preferredColorScheme = preferredColorScheme
            ?? GhosttyApp.shared.effectiveTerminalColorSchemePreference
        let scheme = GhosttyApp.ghosttyRuntimeColorScheme(for: preferredColorScheme)
        if !force, appliedColorScheme == scheme {
            if GhosttyApp.shared.backgroundLogEnabled {
                let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
                GhosttyApp.shared.logBackground(
                    "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=false"
                )
            }
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        if GhosttyApp.shared.backgroundLogEnabled {
            let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
            GhosttyApp.shared.logBackground(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=true"
            )
        }
    }

    @discardableResult
    private func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToView(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    private func requestInputRecoveryAfterSurfaceMiss(reason: String) {
        terminalSurface?.requestBackgroundSurfaceStartIfNeeded()
#if DEBUG
        cmuxDebugLog(
            "focus.input_recovery surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) inWindow=\(window != nil ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func prepareSurfaceForPaste(reason: String) -> Bool {
        guard ensureSurfaceReadyForInput() != nil else {
            requestInputRecoveryAfterSurfaceMiss(reason: reason)
            return false
        }
        return true
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        guard surface != nil else { return false }
        setKeyboardCopyModeActive(!keyboardCopyModeActive)
        if !keyboardCopyModeActive, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
        }
        return true
    }

    private func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeVisualActive = false
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        keyboardCopyModeActive = active
        if active, let surface {
            _ = ghostty_surface_clear_selection_compat(surface)
            keyboardCopyModeCursor = keyboardCopyModeInitialCursor(surface: surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        } else {
            keyboardCopyModeCursor = nil
            syncKeyboardCopyModeCursorOverlay()
        }
        terminalSurface?.setKeyboardCopyModeActive(active)
    }

    private func performBindingAction(_ action: String, repeatCount: Int) {
        let count = terminalKeyboardCopyModeClampCount(repeatCount)
        for _ in 0 ..< count {
            _ = performBindingAction(action)
        }
    }

    private func currentKeyboardCopyModeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
            ?? max(Int(ghostty_surface_size(surface).rows), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, keyboardCopyModeCursor?.row ?? fallback))
    }

    private struct KeyboardCopyModeGridMetrics {
        let rows: Int
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let xInset: CGFloat
        let yInset: CGFloat
        let viewHeight: CGFloat

        func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            CGRect(
                x: xInset + (CGFloat(cursor.column) * cellWidth),
                y: yInset + (CGFloat(cursor.row) * cellHeight),
                width: cellWidth,
                height: cellHeight
            )
        }

        func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            let topOrigin = topOriginRect(for: cursor)
            let rawY = viewHeight - topOrigin.maxY
            let maxY = max(viewHeight - topOrigin.height, 0)
            return CGRect(
                x: topOrigin.minX,
                y: min(max(rawY, 0), maxY),
                width: topOrigin.width,
                height: topOrigin.height
            )
        }
    }

    private func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        let size = ghostty_surface_size(surface)
        let backingRows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(bounds.height),
            cellHeight: Double(resolvedCellHeight)
        )
        let terminalWidth = CGFloat(columns) * resolvedCellWidth
        let terminalHeight = CGFloat(rows) * resolvedCellHeight
        return KeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: resolvedCellWidth,
            cellHeight: resolvedCellHeight,
            xInset: max(0, (bounds.width - terminalWidth) / 2),
            yInset: max(0, (bounds.height - terminalHeight) / 2),
            viewHeight: bounds.height
        )
    }

    private func keyboardCopyModeInitialCursor(surface: ghostty_surface_t) -> TerminalKeyboardCopyModeCursor {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let row = terminalKeyboardCopyModeInitialViewportRow(
            rows: metrics.rows,
            imePointY: y,
            imeCellHeight: Double(metrics.cellHeight),
            topPadding: Double(metrics.yInset)
        )
        let column = terminalKeyboardCopyModeInitialViewportColumn(
            columns: metrics.columns,
            imePointX: x,
            imeCellWidth: Double(metrics.cellWidth),
            leftPadding: Double(metrics.xInset)
        )
        return TerminalKeyboardCopyModeCursor(row: row, column: column)
    }

    private func syncKeyboardCopyModeCursorOverlay(surface explicitSurface: ghostty_surface_t? = nil) {
        guard keyboardCopyModeActive,
              !keyboardCopyModeVisualActive,
              let surface = explicitSurface ?? self.surface,
              let cursor = keyboardCopyModeCursor,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }

        let clampedCursor = cursor.clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCursor != cursor {
            keyboardCopyModeCursor = clampedCursor
        }

        keyboardCopyModeCursorOverlayView.frame = metrics.appKitRect(for: clampedCursor)
        keyboardCopyModeCursorOverlayView.isHidden = false
    }

    private func moveKeyboardCopyModeCursor(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        let scrollDelta = cursor.move(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
        if scrollDelta != 0 {
            _ = performBindingAction("scroll_page_lines:\(scrollDelta)")
        }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func clampKeyboardCopyModeCursor(surface: ghostty_surface_t) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: Int? = nil) {
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = true
        keyboardCopyModePendingViewportJumpScrollbarOffset = scrollbar?.offset
        keyboardCopyModePendingViewportJumpFallbackLineDelta = fallbackLineDelta
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func scheduleKeyboardCopyModeViewportJumpCursorSyncFallback() {
        let generation = keyboardCopyModePendingViewportJumpGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
    }

    private func previewKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration,
              keyboardCopyModeActive,
              let surface else { return }

        if flushPendingScrollbarIfAvailable() {
            return
        }

        if let lineDelta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
           lineDelta != 0,
           keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta == 0 {
            shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: lineDelta, surface: surface)
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = lineDelta
            return
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func expireKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration else { return }

        keyboardCopyModePendingViewportJumpSync = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil
        keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    }

    private func finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: GhosttyScrollbar? = nil) {
        guard keyboardCopyModePendingViewportJumpSync else { return }
        keyboardCopyModePendingViewportJumpSync = false
        defer {
            keyboardCopyModePendingViewportJumpScrollbarOffset = nil
            keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        }

        guard keyboardCopyModeActive, let surface else { return }
        let resolvedNewOffset = newScrollbar?.offset ?? scrollbar?.offset
        if let previousOffset = keyboardCopyModePendingViewportJumpScrollbarOffset,
           let resolvedNewOffset {
            let lineDelta = keyboardCopyModeViewportLineDelta(
                from: previousOffset,
                to: resolvedNewOffset
            )
            let remainingLineDelta = lineDelta - keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta
            if remainingLineDelta != 0 {
                shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: remainingLineDelta, surface: surface)
                return
            }
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func keyboardCopyModeViewportLineDelta(from previousOffset: UInt64, to currentOffset: UInt64) -> Int {
        if currentOffset >= previousOffset {
            return Int(clamping: currentOffset - previousOffset)
        }
        return -Int(clamping: previousOffset - currentOffset)
    }

    private func updateKeyboardCopyModeCursorModel(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.moveAfterTerminalSelectionAdjustment(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
    }

    private func shiftKeyboardCopyModeCursorForViewportScroll(
        lineDelta: Int,
        surface: ghostty_surface_t
    ) {
        guard lineDelta != 0,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.shiftForViewportScroll(lineDelta: lineDelta, rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        let action = "adjust_selection:\(direction.rawValue)"
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        for _ in 0 ..< clampedCount {
            _ = performBindingAction(action)
            updateKeyboardCopyModeCursorModel(direction, count: 1, surface: surface)
        }
    }

    private func selectKeyboardCopyModeCursorCell(surface: ghostty_surface_t) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }

        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor

        let rect = metrics.topOriginRect(for: cursor)
        let y = min(max(rect.midY, 0), max(bounds.height - 1, 0))
        guard let xRange = terminalKeyboardCopyModeCursorSelectionXRange(
            rectMinX: Double(rect.minX),
            rectMaxX: Double(rect.maxX),
            boundsWidth: Double(bounds.width)
        ) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        let mods = GHOSTTY_MODS_NONE

        _ = ghostty_surface_clear_selection_compat(surface)
        ghostty_surface_mouse_pos(surface, xRange.startX, Double(y), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        ghostty_surface_mouse_pos(surface, xRange.endX, Double(y), mods)
        let selectedCursorCell = ghostty_surface_has_selection(surface)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        guard selectedCursorCell else {
            _ = ghostty_surface_clear_selection_compat(surface)
            return false
        }
        return true
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = metrics.rows
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)
        _ = ghostty_surface_clear_selection_compat(surface)

        let yMax = max(bounds.height - 1, 0)

        let startRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: targetRow, column: 0)
        ).midY
        let endRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: endRow, column: max(metrics.columns - 1, 0))
        ).midY
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(bounds.width - 1, 0)
        let startX = min(metrics.xInset + 0.5, xMax)
        let endX = min(metrics.xInset + (CGFloat(metrics.columns) * metrics.cellWidth) - 0.5, xMax)

        let mods = GHOSTTY_MODS_NONE
        ghostty_surface_mouse_pos(surface, Double(startX), Double(startY), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            return false
        }
        defer {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }
        ghostty_surface_mouse_pos(surface, Double(endX), Double(endY), mods)
        guard ghostty_surface_has_selection(surface) else { return false }

        return performBindingAction("copy_to_clipboard")
    }

    private func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }

        if terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
            keyboardCopyModeInputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection; non-visual
        // cursor state is owned by the copy-mode cursor model.
        let hasSelection = keyboardCopyModeVisualActive
        let resolution = terminalKeyboardCopyModeResolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasSelection: hasSelection,
            state: &keyboardCopyModeInputState
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .startSelection:
            if selectKeyboardCopyModeCursorCell(surface: surface) {
                keyboardCopyModeVisualActive = true
                syncKeyboardCopyModeCursorOverlay(surface: surface)
            }
        case .clearSelection:
            keyboardCopyModeVisualActive = false
            _ = ghostty_surface_clear_selection_compat(surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .copyAndExit:
            _ = performBindingAction("copy_to_clipboard")
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case .copyLineAndExit:
            let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
            _ = copyCurrentViewportLinesToClipboard(
                surface: surface,
                startRow: startRow,
                lineCount: count
            )
            _ = ghostty_surface_clear_selection_compat(surface)
            setKeyboardCopyModeActive(false)
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: lineDelta)
            _ = performBindingAction("scroll_page_lines:\(lineDelta)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * rows * clampedCount)
            performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .scrollHalfPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let fraction = delta > 0 ? 0.5 : -0.5
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            let linesPerScroll = Int((Double(rows) * 0.5).rounded(.towardZero))
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * linesPerScroll * clampedCount)
            performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: clampedCount)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .scrollToTop:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.home, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = 0
                    cursor.column = 0
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_top")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .scrollToBottom:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.end, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    let size = ghostty_surface_size(surface)
                    cursor.row = max(Int(size.rows) - 1, 0)
                    cursor.column = max(Int(size.columns) - 1, 0)
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_bottom")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case let .jumpToPrompt(delta):
            beginKeyboardCopyModeViewportJumpCursorSync()
            _ = performBindingAction("jump_to_prompt:\(delta * count)")
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:next", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case .searchPrevious:
            beginKeyboardCopyModeViewportJumpCursorSync()
            performBindingAction("navigate_search:previous", repeatCount: count)
            scheduleKeyboardCopyModeViewportJumpCursorSyncFallback()
        case let .adjustSelection(direction):
            if keyboardCopyModeVisualActive {
                adjustKeyboardCopyModeSelection(direction, count: count, surface: surface)
            } else {
                moveKeyboardCopyModeCursor(direction, count: count, surface: surface)
            }
        }
        return true
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func copyWorkspaceAndSurfaceIdentifiers(_ sender: Any?) {
        guard let terminalSurface else { return }
        let paneId = terminalSurface.owningWorkspace()?.paneId(forPanelId: terminalSurface.id)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: terminalSurface.tabId,
                paneId: paneId,
                surfaceId: terminalSurface.id,
                includeRefs: true
            )
        )
    }

    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        )
    }

    private func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        recordAgentHibernationTerminalInput(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id
        )
    }

    // MARK: - Clipboard paste

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "pasteAsPlainText.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    private func applyConfiguredMenuShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    /// Validates whether edit menu items (copy, paste, split) should be enabled.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(splitHorizontally(_:)), #selector(splitVertically(_:)):
            return canSplitCurrentSurface()
        case #selector(copyWorkspaceAndSurfaceIdentifiers(_:)):
            return terminalSurface != nil
        default:
            return true
        }
    }

    // MARK: - Accessibility

    /// Expose the terminal surface as an editable accessibility element.
    /// Voice input tools frequently target AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        // We don't keep a full terminal text snapshot in this layer.
        // Expose selected text when available; otherwise provide an empty value
        // so AX clients still treat this as an editable text area.
        accessibilitySelectedText() ?? ""
    }

    override func setAccessibilityValue(_ value: Any?) {
        let content: String
        switch value {
        case let v as NSAttributedString:
            content = v.string
        case let v as String:
            content = v
        default:
            return
        }

        guard !content.isEmpty else { return }

#if DEBUG
        cmuxDebugLog("ime.ax.setValue len=\(content.count)")
#endif

        let inject = {
            self.withExternalCommittedText {
                self.insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    private func withExternalCommittedText<T>(_ body: () -> T) -> T {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        return body()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    private func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            let selectedData = Data(bytes: ptr, count: Int(text.text_len))
            selected = String(decoding: selectedData, as: UTF8.self)
        } else {
            selected = ""
        }

        return SelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }

    private func visibleDocumentRectInScreenCoordinates() -> NSRect {
        let localRect = visibleRect
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    private func invalidateTextInputCoordinates(selectionChanged: Bool = false) {
        guard let inputContext else { return }
        inputContext.invalidateCharacterCoordinates()
        guard selectionChanged else { return }

        // `textInputClientDidUpdateSelection` is absent from the Xcode 16.2 AppKit SDK
        // used by the macOS 14 compatibility lane, so call it dynamically when present.
        let updateSelectionSelector = NSSelectorFromString("textInputClientDidUpdateSelection")
        guard inputContext.responds(to: updateSelectionSelector) else { return }
        _ = inputContext.perform(updateSelectionSelector)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        var shouldApplySurfaceFocus = false
        if result {
            imeConsumedKeyUps.removeAll()
            if let terminalSurface,
               AppDelegate.shared?.allowsTerminalKeyboardFocus(
                   workspaceId: terminalSurface.tabId,
                   panelId: terminalSurface.id,
                   in: window
               ) == false {
                desiredFocus = false
                terminalSurface.recordExternalFocusState(false)
#if DEBUG
                dlog("focus.firstResponder SUPPRESSED (coordinator) surface=\(terminalSurface.id.uuidString.prefix(5))")
#endif
                return result
            }

            // If we become first responder before the ghostty surface exists (e.g. during
            // split/tab creation while the surface is still being created), record the desired focus.
            desiredFocus = true

            // During programmatic splits, SwiftUI reparents the old NSView which triggers
            // becomeFirstResponder. Suppress onFocus + ghostty_surface_set_focus to prevent
            // the old view from stealing focus and creating model/surface divergence.
            if suppressingReparentFocus {
#if DEBUG
                cmuxDebugLog("focus.firstResponder SUPPRESSED (reparent) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                return result
            }

            // Always notify the host app that this pane became the first responder so bonsplit
            // focus/selection can converge. Previously this was gated on `surface != nil`, which
            // allowed a mismatch where AppKit focus moved but the UI focus indicator (bonsplit)
            // stayed behind.
            let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
            if isVisibleInUI && hasUsableFocusGeometry && !hiddenInHierarchy {
                shouldApplySurfaceFocus = true
                onFocus?()
            } else if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
#if DEBUG
                cmuxDebugLog(
                    "focus.firstResponder SUPPRESSED (hidden_or_tiny) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) hidden=\(hiddenInHierarchy ? 1 : 0)"
                )
#endif
            }
        }
        if result, shouldApplySurfaceFocus, let surface = ensureSurfaceReadyForInput() {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
#if DEBUG
            cmuxDebugLog("focus.firstResponder surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            if let terminalSurface {
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: [
                        GhosttyNotificationKey.tabId: terminalSurface.tabId,
                        GhosttyNotificationKey.surfaceId: terminalSurface.id,
                    ]
                )
            }
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)

            // Ghostty only restarts its vsync display link on display-id changes while focused.
            // During rapid split close / SwiftUI reparenting, the view can reattach to a window
            // and get its display id set *before* it becomes first responder; in that case, the
            // renderer can remain stuck until some later screen/focus transition. Reassert the
            // display id now that we're focused to ensure the renderer is running.
            if let displayID = window?.screen?.displayID, displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
            terminalSurface?.forceRefresh(reason: "focus.firstResponder")
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            imeConsumedKeyUps.removeAll()
            desiredFocus = false
            terminalSurface?.recordExternalFocusState(false)
        }
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("resignFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // For NSTextInputClient - accumulates text during key events
    private(set) var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var lastPerformKeyEvent: TimeInterval?
    private(set) var externalCommittedTextDepth = 0
    var numpadIMECommitDeduplicator = NumpadIMECommitDeduplicator()
    private struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

#if DEBUG
    // Test-only accessors for keyTextAccumulator to verify CJK IME composition behavior.
    func setKeyTextAccumulatorForTesting(_ value: [String]?) {
        keyTextAccumulator = value
    }
    var keyTextAccumulatorForTesting: [String]? {
        keyTextAccumulator
    }
    func shouldSuppressShiftSpaceFallbackTextForTesting(event: NSEvent, markedTextBefore: Bool) -> Bool {
        shouldSuppressShiftSpaceFallbackText(event: event, markedTextBefore: markedTextBefore)
    }
    // Test-only IME point override so firstRect behavior can be regression tested.
    private var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?
    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) { imePointOverrideForTesting = (x, y, width, height) }
    func clearIMEPointForTesting() { imePointOverrideForTesting = nil }
#endif

#if DEBUG
    private func recordKeyLatency(path: String, event: NSEvent) {
        guard Self.keyLatencyProbeEnabled else { return }
        CmuxTypingTiming.logEventDelay(path: path, event: event)
    }
#endif

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    /// Some third-party voice input apps inject committed text by sending the
    /// responder-chain `insertText:` action (single-argument form).
    /// Route that into our NSTextInputClient path so text lands in the terminal.
    override func insertText(_ insertString: Any) {
        withExternalCommittedText {
            insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: true)
    }

    func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: false)
    }

    private func performKeyEquivalent(with event: NSEvent, shouldRetryMainMenu: Bool) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
#endif
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface = ensureSurfaceReadyForInput() else { return false }

        // Let non-Cmd keys flow to keyDown while IME is composing; Cmd shortcuts still work.
        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Printable text without Command/Control should stay on the normal keyDown
        // path. AppKit can still route layout-dependent punctuation through
        // performKeyEquivalent first, and probing bindings here can misclassify
        // keys such as ABC-QWERTZ Shift+7 ("/") or Shift+- ("?") as shortcuts.
        if !flags.contains(.command),
           !flags.contains(.control),
           let text = textForKeyEvent(event),
           shouldSendText(text) {
            lastPerformKeyEvent = nil
            return false
        }

#if DEBUG
        recordKeyLatency(path: "performKeyEquivalent", event: event)
#endif

#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probePerformCharsHex": cmuxScalarHex(event.characters),
                "probePerformCharsIgnoringHex": cmuxScalarHex(event.charactersIgnoringModifiers),
                "probePerformKeyCode": String(event.keyCode),
                "probePerformModsRaw": String(event.modifierFlags.rawValue),
                "probePerformSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probePerformKeyEquivalentCount": 1]
        )
#endif

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            // Performable bindings (e.g. paste_from_clipboard) also need the menu
            // path so that Edit > Paste handles Cmd+V instead of keyDown double-
            // firing the clipboard request through both interpretKeyEvents and
            // ghostty_surface_key.
            if shouldRetryMainMenu && isConsumed && !isAll && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            // For performable bindings where the menu didn't handle the event,
            // fall through to keyDown so Ghostty can perform the action directly
            // (e.g. paste when no menu item exists).
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Match AppKit key-equivalent routing for menu-style shortcuts (Command-modified).
            // Control-only terminal input (e.g. Ctrl+D) should not participate in redispatch;
            // it must flow through the normal keyDown path exactly once.
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }

            if !shouldRetryMainMenu { lastPerformKeyEvent = nil; keyDown(with: event); return true }
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.charactersIgnoringModifiers ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp; return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var dismissNotificationMs: Double = 0
        var keyboardCopyModeMs: Double = 0
        var interpretMs: Double = 0
        var syncPreeditMs: Double = 0
        var ghosttySendMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "terminal.keyDown.phase",
                totalMs: totalMs,
                event: event,
                thresholdMs: 1.0,
                parts: [
                    ("ensureSurfaceMs", ensureSurfaceMs),
                    ("dismissNotificationMs", dismissNotificationMs),
                    ("keyboardCopyModeMs", keyboardCopyModeMs),
                    ("interpretMs", interpretMs),
                    ("syncPreeditMs", syncPreeditMs),
                    ("ghosttySendMs", ghosttySendMs),
                ],
                extra: "marked=\(hasMarkedText() ? 1 : 0)"
            )
            CmuxTypingTiming.logDuration(path: "terminal.keyDown", startedAt: typingTimingStart, event: event)
        }
        let ensureSurfaceStart = ProcessInfo.processInfo.systemUptime
#endif
        guard let surface = ensureSurfaceReadyForInput() else {
            requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface")
#if DEBUG
            ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
            super.keyDown(with: event)
            return
        }
        recordDirectAgentHibernationTerminalInput()
#if DEBUG
        ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
        if let mode = RightSidebarMode.modeShortcut(for: event), let window, AppDelegate.shared?.shouldRouteRightSidebarModeShortcut(in: window) == true {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
            return
        }
        if let terminalSurface {
#if DEBUG
            let dismissNotificationStart = ProcessInfo.processInfo.systemUptime
#endif
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
#if DEBUG
            dismissNotificationMs = (ProcessInfo.processInfo.systemUptime - dismissNotificationStart) * 1000.0
#endif
        }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if !cmuxFindEventIsPlainEscape(event) { endFindEscapeSuppression() }
        if shouldConsumeSuppressedFindEscape(event) { return }
        if cmuxFindEventIsPlainEscape(event), !hasMarkedText(), let terminalSurface, terminalSurface.searchState != nil {
            terminalSurface.searchState = nil
            beginFindEscapeSuppression(); return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            keyboardCopyModeConsumedKeyUps.insert(event.keyCode)
            return
        }
#if DEBUG
        keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeKeyDownCharsHex": cmuxScalarHex(event.characters),
                "probeKeyDownCharsIgnoringHex": cmuxScalarHex(event.charactersIgnoringModifiers),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                handled = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ctrlGhosttySend",
                    event: event
                )
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                handled = ghostty_surface_key(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = CmuxTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
                #if DEBUG
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "terminal.keyDown.ctrlGhosttySend",
                    startedAt: sendTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
                #endif
            }
#if DEBUG
            cmuxDebugLog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\(cmuxScalarHex(event.characters)) " +
                "ign=\(cmuxScalarHex(event.charactersIgnoringModifiers)) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            // If Ghostty handled the key (action/encoding), we're done.
            // If not (e.g. `ignore` keybind), fall through to interpretKeyEvents
            // so the IME gets a chance to process this event.
            if handled { return }
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }
        let textInputEvent = textInputInterpretationEvent(
            original: event,
            translated: translationEvent
        )

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let markedStateBefore = (markedText.string, markedSelectedRange)

        // Capture the keyboard layout ID before interpretation so the IME
        // forwarding decision uses the source that saw this key.
        let keyboardIdBefore = KeyboardLayout.id

        // Let the input system handle the event (for IME, dead keys, etc.)
#if DEBUG
        let interpretTimingStart = CmuxTypingTiming.start()
        let interpretPhaseStart = ProcessInfo.processInfo.systemUptime
#endif
#if DEBUG
        if let debugTextInputEventHandler = Self.debugTextInputEventHandler {
            let handled = debugTextInputEventHandler(self, textInputEvent)
            if !handled {
                interpretKeyEvents([textInputEvent])
            }
        } else {
            interpretKeyEvents([textInputEvent])
        }
#else
        interpretKeyEvents([textInputEvent])
#endif
#if DEBUG
        interpretMs = (ProcessInfo.processInfo.systemUptime - interpretPhaseStart) * 1000.0
        CmuxTypingTiming.logDuration(
            path: "terminal.keyDown.interpretKeyEvents",
            startedAt: interpretTimingStart,
            event: event
        )
#endif

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if !markedTextBefore, let kbBefore = keyboardIdBefore, kbBefore != KeyboardLayout.id {
            imeConsumedKeyUps.insert(event.keyCode)
#if DEBUG
            let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
            syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
            syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif
            return
        }

        // Sync preedit so Ghostty can render the IME composition overlay.
#if DEBUG
        let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
        syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
        syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif

        let accumulatedText = keyTextAccumulator ?? []
        if shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: markedStateBefore,
            after: (markedText.string, markedSelectedRange),
            accumulatedText: accumulatedText,
            event: textInputEvent,
            inputSourceId: keyboardIdBefore
        ) {
            imeConsumedKeyUps.insert(event.keyCode)
            return
        }

        // A forwarded keyDown owns its keyUp. Clear any stale IME suppression
        // entry left by an earlier suppressed repeat for the same physical key.
        imeConsumedKeyUps.remove(event.keyCode)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Treat cleared preedit as composing too, so a composing Backspace cancels
        // composition without deleting the preceding terminal input.
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key
        if !accumulatedText.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.accumulatedGhosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.accumulatedGhosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.accumulatedGhosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            }

            if shouldSendCommittedIMEConfirmKey(
                event: textInputEvent,
                markedTextBefore: markedTextBefore
            ) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
#if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.accumulatedConfirmGhosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
#else
                _ = ghostty_surface_key(surface, keyEvent)
#endif
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressShiftSpaceFallbackText =
                shouldSuppressShiftSpaceFallbackText(
                    event: translationEvent,
                    markedTextBefore: markedTextBefore
                )
            let suppressComposingFallbackText = keyEvent.composing
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text),
                   !suppressShiftSpaceFallbackText,
                   !suppressComposingFallbackText {
                    var handled = false
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        handled = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.ghosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        handled = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
                    if handled {
                        notePotentialDeferredNumpadIMECommit(text: text, event: event)
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.ghosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "handled=\(handled ? 1 : 0) textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.ghosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ghosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                _ = ghostty_surface_key(surface, keyEvent)
                #endif
            }
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    @discardableResult
    private func sendGhosttyKey(_ surface: ghostty_surface_t, _ keyEvent: ghostty_input_key_s) -> Bool {
#if DEBUG
        Self.debugGhosttySurfaceKeyEventObserver?(keyEvent)
#endif
        return ghostty_surface_key(surface, keyEvent)
    }

#if DEBUG
    @discardableResult
    private func sendTimedGhosttyKey(
        _ surface: ghostty_surface_t,
        _ keyEvent: ghostty_input_key_s,
        path: String,
        event: NSEvent? = nil,
        extra: String? = nil
    ) -> Bool {
        let timingStart = CmuxTypingTiming.start()
        let handled = sendGhosttyKey(surface, keyEvent)
        let baseExtra = "handled=\(handled ? 1 : 0)"
        let mergedExtra: String
        if let extra, !extra.isEmpty {
            mergedExtra = "\(baseExtra) \(extra)"
        } else {
            mergedExtra = baseExtra
        }
        CmuxTypingTiming.logDuration(path: path, startedAt: timingStart, event: event, extra: mergedExtra)
        return handled
    }
#endif

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyUp(with: event)
            return
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
        if event.keyCode == 53 {
            endFindEscapeSuppression()
        }

        if keyboardCopyModeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }
        if imeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }

        // Build release events from the same translation path as keyDown so
        // consumers that depend on precise key identity (for example Space
        // hold/release flows) receive consistent metadata.
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = sendGhosttyKey(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        if !hasMarkedText(),
           let action = cmuxGhosttyModifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
           ) {
            // `flagsChanged` carries modifier-only state, not textual key input.
            // Building this via `ghosttyKeyEvent(for:surface:)` would fall through
            // to `unshiftedCodepointFromEvent`, which probes AppKit character APIs
            // that are not safe for modifier-only events.
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            _ = sendGhosttyKey(surface, keyEvent)
        }

        let selectionActive = ghostty_surface_has_selection(surface)
        let suppressCommandPathHover = event.modifierFlags.contains(.command) && selectionActive
        // Refresh ghostty's mouse position so quicklook_word uses current coordinates
        // when Cmd is pressed while the pointer is stationary.
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
#if DEBUG
        if event.modifierFlags.contains(.command) || selectionActive {
            runtimeDebugLog(
                hypothesisID: "h1",
                name: "flags_changed",
                expected: "selection active should suppress cmd-hover",
                actual: suppressCommandPathHover ? "suppressed" : "forwarded",
                data: [
                    "flags": debugModifierString(event.modifierFlags),
                    "selection_active": selectionActive,
                    "point_x": eventPoint.x,
                    "point_y": eventPoint.y,
                    "resolved_point_x": point.x,
                    "resolved_point_y": point.y
                ]
            )
        }
#endif
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func shouldSuppressCommandPathHover(for flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    private func hoverModsFromFlags(
        _ flags: NSEvent.ModifierFlags,
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? flags.subtracting(.command) : flags
#if DEBUG
        if suppressCommandPathHover, flags.contains(.command) {
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return modsFromFlags(effectiveFlags)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        isFindEscapeSuppressionArmed && cmuxFindEventIsPlainEscape(event)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        if let layoutChars = KeyboardLayout.character(forKeyCode: event.keyCode),
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    private func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Korean IME: Enter commits the syllable AND executes the command (single step).
        // Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
        // Only send the extra Return key for Korean input sources.
        guard let sourceId = KeyboardLayout.id else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            let name: String
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                name = String(data: data, encoding: .utf8) ?? ""
            } else {
                name = ""
            }
            keyTables.append(name)
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }

        terminalSurface?.hostedView.syncKeyStateIndicator(text: currentKeyStateIndicatorText)
    }

    // MARK: - Mouse Handling

    #if DEBUG
    private func debugModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.control) ? "ctrl" : nil,
            flags.contains(.option) ? "opt" : nil,
        ].compactMap { $0 }.joined(separator: "+")
    }

    private func runtimeDebugLog(
        hypothesisID: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        var payload = data
        payload["surface_id"] = terminalSurface?.id.uuidString ?? "nil"
        payload["word_path_hover_active"] = wordPathHoverActive
        CmuxRuntimeDebugCapture.logIfConfigured(
            hypothesisID: hypothesisID,
            source: "GhosttyNSView.\(name)",
            name: name,
            expected: expected,
            actual: actual,
            data: payload
        )
    }

    private func runtimeDebugResolutionPayload(_ resolution: WordPathResolution?) -> [String: Any] {
        guard let resolution else {
            return [
                "resolution_source": "none",
                "resolved_path_basename": "",
                "raw_token": ""
            ]
        }

        return [
            "resolution_source": resolution.source.rawValue,
            "resolved_path_basename": URL(fileURLWithPath: resolution.path).lastPathComponent,
            "raw_token": resolution.rawToken
        ]
    }
    #endif

    private func requestPointerFocusRecovery() {
#if DEBUG
        cmuxDebugLog("focus.pointerDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        onFocus?()
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let debugPoint = convert(event.locationInWindow, from: nil)
        cmuxDebugLog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        // Split reparent/layout churn can suppress the later `becomeFirstResponder -> onFocus`
        // callback. Treat pointer-down as explicit focus intent so clicking a ghost pane still
        // repairs workspace/pane active state before key routing runs.
        if let terminalSurface {
            if terminalSurface.focusPlacement == .rightSidebarDock {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
            } else {
                AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                    workspaceId: terminalSurface.tabId,
                    panelId: terminalSurface.id,
                    in: window
                )
            }
            terminalSurface.hostedView.clearReparentFocusSuppressionForPointerFocus()
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        if let terminalSurface {
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        }
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        hasPendingLeftMouseRelease = true
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        cmuxDebugLog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        completePendingLeftMouseRelease(with: event)
    }

    @discardableResult
    func forwardPendingLeftMouseDrag(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease, let surface else { return false }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
        return true
    }

    @discardableResult
    func completePendingLeftMouseRelease(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease else { return false }
        hasPendingLeftMouseRelease = false
        guard let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        _ = handleCommandClickRelease(at: point, modifierFlags: event.modifierFlags, ghosttyConsumed: consumed)
        return true
    }

    /// Attempt to open the word under the mouse cursor as a file path, resolved
    /// against the terminal panel's current working directory.
    private func tryOpenWordAsPath(at point: NSPoint? = nil) {
        guard let resolution = resolveWordUnderCursorPath(at: point) else { return }

        #if DEBUG
        cmuxDebugLog("link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue)")
        #endif

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
    }

    /// Check if the word under the mouse cursor resolves to an existing file/directory
    /// in the terminal panel's CWD. Returns the resolved absolute path, or nil.
    private func resolveWordUnderCursorAsPath(at point: NSPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: point)?.path
    }

    private func resolveWordUnderCursorPath(at point: NSPoint? = nil) -> WordPathResolution? {
        guard let surface = surface else { return nil }

        guard let termSurface = terminalSurface,
              let workspace = termSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(termSurface.id) else { return nil }

        guard let cwd = resolvedWordPathWorkingDirectory(workspace: workspace, terminalSurface: termSurface) else {
            return nil
        }

        let snapshotPoint = preferredPointerPoint(from: point)
        let pointSnapshotResolution = snapshotPoint.flatMap {
            resolveVisibleWordPath(
                at: $0,
                cwd: cwd,
                workspace: workspace,
                terminalSurface: termSurface
            )
        }

        var text = ghostty_text_s()
        if ghostty_surface_quicklook_word(surface, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            var quicklookResolution: WordPathResolution?
            if text.text_len > 0, let ptr = text.text {
                let wordData = Data(bytes: ptr, count: Int(text.text_len))
                if let decodedWord = String(bytes: wordData, encoding: .utf8) {
#if DEBUG
                    let resolvedQuicklookWord = cmuxTerminalCmdClickQuicklookOverride(decodedWord)
#else
                    let resolvedQuicklookWord = decodedWord
#endif
                    if let resolvedPath = cmuxResolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                        quicklookResolution = makeWordPathResolution(
                            path: resolvedPath,
                            source: .quicklook,
                            rawToken: resolvedQuicklookWord
                        )
                    }
                }
            }

            var viewportResolution: WordPathResolution?
            if text.offset_len > 0 {
#if DEBUG
                let viewportOffsetStart = cmuxTerminalCmdClickViewportOffsetDelta(Int(text.offset_start))
#else
                let viewportOffsetStart = Int(text.offset_start)
#endif
                viewportResolution = resolveVisibleWordPathFromViewportOffset(
                    viewportOffsetStart,
                    cwd: cwd,
                    workspace: workspace,
                    terminalSurface: termSurface
                )
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    #if DEBUG
    private func cmuxTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    private func cmuxTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
    #endif

    /// Update the pointing-hand cursor when Cmd-hovering over a bare filename
    /// that exists in the terminal's CWD.
    private func updateWordPathHover(
        at point: NSPoint? = nil,
        cmdHeld: Bool,
        suppressPathHover: Bool = false
    ) {
        let hoverWasActive = wordPathHoverActive
        guard cmdHeld, !suppressPathHover else {
            if wordPathHoverActive {
                wordPathHoverActive = false
                NSCursor.pop()
            }
#if DEBUG
            if cmdHeld || suppressPathHover || hoverWasActive {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "hover_update",
                    expected: "cmd-hover off while selection is active",
                    actual: suppressPathHover ? "suppressed" : "inactive",
                    data: [
                        "cmd_held": cmdHeld,
                        "suppress_path_hover": suppressPathHover,
                        "hover_active_before": hoverWasActive,
                        "hover_active_after": wordPathHoverActive
                    ]
                )
            }
#endif
            return
        }

        let resolution = resolveWordUnderCursorPath(at: point)
        if resolution != nil {
            if !wordPathHoverActive {
                wordPathHoverActive = true
                NSCursor.pointingHand.push()
            }
        } else if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        if cmdHeld || hoverWasActive || wordPathHoverActive || resolution != nil {
            var payload: [String: Any] = [
                "cmd_held": cmdHeld,
                "suppress_path_hover": suppressPathHover,
                "hover_active_before": hoverWasActive,
                "hover_active_after": wordPathHoverActive
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: resolution == nil ? "h1" : "h2",
                name: "hover_update",
                expected: "resolved path only when hover should activate",
                actual: wordPathHoverActive ? "hover_active" : "hover_inactive",
                data: payload
            )
        }
#endif
    }

    private func resolvedWordPathWorkingDirectory(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> String? {
        CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
    }

    private func pointIsUsableForWordResolution(_ point: NSPoint) -> Bool {
        bounds.width > 0 &&
        bounds.height > 0 &&
        point.x >= 0 &&
        point.y >= 0 &&
        point.x <= bounds.width &&
        point.y <= bounds.height
    }

    private func trackMousePointIfUsable(_ point: NSPoint) {
        guard pointIsUsableForWordResolution(point) else { return }
        lastKnownMousePointInView = point
    }

    private func preferredPointerPoint(from eventPoint: NSPoint? = nil) -> NSPoint? {
        if let eventPoint, pointIsUsableForWordResolution(eventPoint) {
            lastKnownMousePointInView = eventPoint
            return eventPoint
        }
        if let currentPoint = currentMousePointInView(), pointIsUsableForWordResolution(currentPoint) {
            lastKnownMousePointInView = currentPoint
            return currentPoint
        }
        return lastKnownMousePointInView ?? eventPoint
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / cols))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, viewportOffsetStart % cols))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    private func resolveVisibleWordPath(
        at point: NSPoint,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = cmuxVisibleTerminalLines(from: visibleText, rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(cols) * resolvedCellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * resolvedCellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / resolvedCellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, Int((point.x - xInset) / resolvedCellWidth)))
        guard let resolution = cmuxResolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    @discardableResult
    private func handleCommandClickRelease(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        ghosttyConsumed: Bool
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let resolvedPoint = preferredPointerPoint(from: point)
        guard cmdHeld, !suppressCommandPathHover else {
#if DEBUG
            if cmdHeld || suppressCommandPathHover {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "command_click_release",
                    expected: "cmd-click fallback only when selection is inactive",
                    actual: suppressCommandPathHover ? "suppressed" : "not_cmd_click",
                    data: [
                        "flags": debugModifierString(modifierFlags),
                        "ghostty_consumed": ghosttyConsumed,
                        "point_x": point.x,
                        "point_y": point.y,
                        "resolved_point_x": resolvedPoint?.x ?? -1,
                        "resolved_point_y": resolvedPoint?.y ?? -1,
                        "suppress_path_hover": suppressCommandPathHover
                    ]
                )
            }
#endif
            return nil
        }

        // Refresh ghostty's cached mouse position so quicklook_word reads
        // up-to-date coordinates (mouseDown skips pos update on double-click).
        if let resolvedPoint {
            ghostty_surface_mouse_pos(
                surface,
                resolvedPoint.x,
                bounds.height - resolvedPoint.y,
                modsFromFlags(modifierFlags)
            )
        }

        guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else {
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h2",
                name: "command_click_release",
                expected: "cmd-click should resolve the token under the pointer",
                actual: "no_resolution",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y,
                    "resolved_point_x": resolvedPoint?.x ?? -1,
                    "resolved_point_y": resolvedPoint?.y ?? -1
                ]
            )
#endif
            return nil
        }
        guard !ghosttyConsumed || resolution.source == .snapshot else {
#if DEBUG
            var payload: [String: Any] = [
                "flags": debugModifierString(modifierFlags),
                "ghostty_consumed": ghosttyConsumed,
                "point_x": point.x,
                "point_y": point.y,
                "resolved_point_x": resolvedPoint?.x ?? -1,
                "resolved_point_y": resolvedPoint?.y ?? -1,
                "suppress_path_hover": suppressCommandPathHover
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "ghostty-consumed clicks should only skip fallback for real ghostty targets",
                actual: "consumed_quicklook_resolution_skipped",
                data: payload
            )
#endif
            return nil
        }

        #if DEBUG
        cmuxDebugLog(
            "link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue) consumed=\(ghosttyConsumed ? 1 : 0)"
        )
        var payload: [String: Any] = [
            "flags": debugModifierString(modifierFlags),
            "ghostty_consumed": ghosttyConsumed,
            "point_x": point.x,
            "point_y": point.y,
            "resolved_point_x": resolvedPoint?.x ?? -1,
            "resolved_point_y": resolvedPoint?.y ?? -1,
            "suppress_path_hover": suppressCommandPathHover
        ]
        for (key, value) in runtimeDebugResolutionPayload(resolution) {
            payload[key] = value
        }
        runtimeDebugLog(
            hypothesisID: resolution.source == .snapshot ? "h3" : "h2",
            name: "command_click_release",
            expected: "cmd-click should open the resolved path",
            actual: "opening_resolved_path",
            data: payload
        )
        #endif

        // Remote-surface guard runs before shouldRoute so we never stat a local
        // path on the main thread for a remote workspace. When the cmux route
        // is applicable but split creation fails, fall back to the preferred
        // editor so the click never silently no-ops.
        if let termSurface = terminalSurface,
           let workspace = termSurface.owningWorkspace(),
           !workspace.isRemoteTerminalSurface(termSurface.id),
           CommandClickFileOpenRouter.openInCmux(
               workspace: workspace,
               sourcePanelId: termSurface.id,
               filePath: resolution.path
           ) {
            return resolution
        }

        PreferredEditorSettings.open(URL(fileURLWithPath: resolution.path))
        return resolution
    }

    private func clampedDebugPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, 1), max(bounds.width - 1, 1)),
            y: min(max(point.y, 1), max(bounds.height - 1, 1))
        )
    }

#if DEBUG
    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        guard let surface else { return false }
        let start = clampedDebugPoint(startPoint)
        let end = clampedDebugPoint(endPoint)
        let mods = GHOSTTY_MODS_NONE

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, start.x, bounds.height - start.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)

        let steps = max(4, Int(max(abs(end.x - start.x), abs(end.y - start.y)) / max(cellSize.width, 1)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = NSPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            let clampedIntermediatePoint = clampedDebugPoint(intermediatePoint)
            ghostty_surface_mouse_pos(
                surface,
                clampedIntermediatePoint.x,
                bounds.height - clampedIntermediatePoint.y,
                mods
            )
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        return ghostty_surface_has_selection(surface)
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        guard let surface else { return false }
        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )
        return suppressCommandPathHover
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )

        let resolution = suppressCommandPathHover ? nil : resolveWordUnderCursorPath(at: clampedPoint)
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )

        var payload: [String: Any] = [
            "hoverActive": wordPathHoverActive ? "1" : "0",
            "suppressed": suppressCommandPathHover ? "1" : "0"
        ]
        if let resolution {
            payload["resolvedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let mods = modsFromFlags(flags)

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, mods)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        let resolution = handleCommandClickRelease(
            at: clampedPoint,
            modifierFlags: flags,
            ghosttyConsumed: releaseConsumed
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
        if let resolution {
            payload["openedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }
#endif

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            requestPointerFocusRecovery()
            super.rightMouseDown(with: event)
            return
        }

        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.triggerFlash", defaultValue: "Trigger Flash"),
                action: #selector(triggerFlash(_:)),
                keyEquivalent: ""
            )
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let pasteItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        menu.addItem(.separator())
        let splitHorizontallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHorizontallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitDown), to: splitHorizontallyItem)
        splitHorizontallyItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        let splitVerticallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: ""
        )
        splitVerticallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitRight), to: splitVerticallyItem)
        splitVerticallyItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        appendMoveCurrentSurfaceMoveMenuItems(to: menu); menu.addItem(.separator())
        let resetTerminalItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.resetTerminal", defaultValue: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            keyEquivalent: ""
        )
        resetTerminalItem.target = self
        resetTerminalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise",
            accessibilityDescription: nil
        )
        if terminalSurface != nil {
            menu.addItem(.separator())
            let identifiersItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                action: #selector(copyWorkspaceAndSurfaceIdentifiers(_:)),
                keyEquivalent: ""
            )
            identifiersItem.target = self
            let linkItem = menu.addItem(
                withTitle: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                action: #selector(copyCurrentSurfaceLink(_:)),
                keyEquivalent: ""
            )
            linkItem.target = self
        }
        return menu
    }

    private func canSplitCurrentSurface() -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return workspace.panels[surfaceId] != nil
    }

    @objc private func splitHorizontally(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .down)
    }

    @objc private func splitVertically(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .right)
    }

    @discardableResult
    private func splitCurrentSurface(direction: SplitDirection) -> Bool {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
            return false
        }
        return manager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        _ = performBindingAction("reset")
    }

    override func mouseMoved(with event: NSEvent) {
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        let alreadyFirstResponder = window.firstResponder === self
        let shouldRequest = Self.shouldRequestFirstResponderForMouseFocus(
            focusFollowsMouseEnabled: GhosttyApp.shared.focusFollowsMouseEnabled(),
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            appIsActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: isVisibleInUI,
            hasUsableGeometry: hasUsableFocusGeometry,
            hiddenInHierarchy: isHiddenOrHasHiddenAncestor
        )
        guard shouldRequest else { return }
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Forward the raw drag coordinates, including out-of-bounds positions.
        // Selection auto-scroll depends on libghostty observing the pointer leave
        // the viewport rather than a cached in-bounds hover point.
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, modsFromEvent(event))
    }

#if DEBUG
    func debugHasPendingLeftMouseReleaseForTesting() -> Bool {
        hasPendingLeftMouseRelease
    }
#endif

    override func scrollWheel(with event: NSEvent) {
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: self)
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        GhosttyApp.shared.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
#if DEBUG
        cmuxDebugLog(
            "surface.view.deinit view=\(Unmanaged.passUnretained(self).toOpaque()) " +
            "surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0)"
        )
#endif
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        if let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    fileprivate static func escapeDropForShell(_ value: String) -> String {
        TerminalImageTransferPlanner.escapeForShell(value)
    }

    static func dropPlanForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool
    ) -> DropPlan {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        switch TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        ) {
        case .insertText(let text):
            return .insertText(text)
        case .insertTextSegments(let segments, _):
            return .insertText(segments.joined())
        case .uploadFiles(let fileURLs, _):
            return .uploadFiles(fileURLs)
        case .reject:
            return .reject
        }
    }

    static func performRemoteDropUploadForTesting(
        upload: (@escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        upload { result in
            switch result {
            case .success(let remotePaths):
                let content = remotePaths
                    .map { Self.escapeDropForShell($0) }
                    .joined(separator: " ")
                guard !content.isEmpty else {
                    onFailure()
                    return
                }
                sendText(content)
            case .failure:
                onFailure()
            }
        }
    }

    @discardableResult
    static func handleDropForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool,
        uploadRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        )
        guard plan != .reject else { return false }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            uploadWorkspaceRemote: { urls, _, finish in
                uploadRemote(urls) { result in
                    finish(result)
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(urls)
                }
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "cmux.remote.drop", code: 4)))
            },
            insertText: sendText,
            onFailure: { _ in onFailure() }
        )
        return true
    }

    private func executeImageTransferPlan(
        _ plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        onCancel: @escaping () -> Void = {}
    ) -> Bool {
        guard plan != .reject else { return false }

        let operation = operation ?? {
            if case .uploadFiles = plan {
                return TerminalImageTransferOperation()
            }
            return nil
        }()

        if let operation {
            terminalSurface?.hostedView.beginImageTransferIndicator(
                for: operation,
                onCancel: onCancel
            )
        }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: { [weak self] fileURLs, operation, finish in
                guard let workspace = MainActor.assumeIsolated({
                    self?.terminalSurface?.owningWorkspace()
                }) else {
                    finish(.failure(NSError(domain: "cmux.remote.drop", code: 3)))
                    GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }
                workspace.uploadDroppedFilesForRemoteTerminal(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            uploadDetectedSSH: { session, fileURLs, operation, finish in
                session.uploadDroppedFiles(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            insertText: { [weak self] text in
                let send = {
                    if let operation {
                        self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                    }
                    // Use the text/paste path (ghostty_surface_text) instead of the key event
                    // path (ghostty_surface_key) so bracketed paste mode is triggered and the
                    // insertion is instant, matching upstream Ghostty behaviour.
                    self?.terminalSurface?.sendText(text)
                }
                if Thread.isMainThread {
                    send()
                } else {
                    DispatchQueue.main.async(execute: send)
                }
            },
            onFailure: { [weak self] _ in
                if let operation {
                    self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                }
                DispatchQueue.main.async {
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.failed surface=\(self?.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
        return true
    }

    private func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        MainActor.assumeIsolated {
            terminalSurface?.resolvedImageTransferTarget() ?? .local
        }
    }

    func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
        executePreparedImageTransfer(
            .fileURLs(urls),
            onCancel: {}
        )
    }

    @discardableResult
    fileprivate func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        executePreparedImageTransfer(
            TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .drop
            ),
            onCancel: {}
        )
    }

    @discardableResult
    private func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        onCancel: @escaping () -> Void
    ) -> Bool {
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            terminalSurface?.sendText(text)
            return true
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(),
                mode: .drop
            )
            return executeImageTransferPlan(plan, onCancel: onCancel)
        }
    }

#if DEBUG
    fileprivate enum DebugDropPayloadKind {
        case fileURLs
        case imageData
    }

    @discardableResult
    fileprivate func debugSimulateFileDrop(
        paths: [String],
        asImageData: Bool = false
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        let pbName = NSPasteboard.Name("cmux.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        switch asImageData ? DebugDropPayloadKind.imageData : .fileURLs {
        case .fileURLs:
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        case .imageData:
            let items = paths.compactMap { path -> NSPasteboardItem? in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url),
                      let type = debugImagePasteboardType(for: url) else { return nil }
                let item = NSPasteboardItem()
                item.setData(data, forType: type)
                return item
            }
            guard items.count == paths.count else { return false }
            pasteboard.writeObjects(items)
        }
        return insertDroppedPasteboard(pasteboard)
    }

    private func debugImagePasteboardType(for url: URL) -> NSPasteboard.PasteboardType? {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utType = UTType(filenameExtension: pathExtension),
              utType.conforms(to: .image) else { return nil }
        return NSPasteboard.PasteboardType(utType.identifier)
    }

    fileprivate func debugRegisteredDropTypes() -> [String] {
        (registeredDraggedTypes ?? []).map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        // Defer to bonsplit when a tab/session drag is in flight: bonsplit's pane
        // drop overlays should win over the terminal's text/file drop handling.
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return false
        }
        #if DEBUG
        cmuxDebugLog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

extension Notification.Name {
    static let ghosttyDidTick = Notification.Name("ghosttyDidTick")
    static let ghosttyDidRenderFrame = Notification.Name("ghosttyDidRenderFrame")
    static let terminalSurfaceDidCompleteClipboardRead = Notification.Name("terminalSurfaceDidCompleteClipboardRead")
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttyDidReceiveWheelScroll = Notification.Name("ghosttyDidReceiveWheelScroll")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures to the terminal surface so Ghostty handles scrollback.
        // Letting NSScrollView consume these events moves the wrapper viewport itself,
        // which causes pane-content drift instead of terminal scrollback movement.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class TerminalViewportBorderOverlayView: NSView {
    var effectiveSize: CGSize? {
        didSet { needsDisplay = true }
    }

    var drawsVisibleAreaBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaRightBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaBottomBorder = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsVisibleAreaBorder,
              let effectiveSize,
              effectiveSize.width > 1,
              effectiveSize.height > 1 else {
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        let width = min(effectiveSize.width, bounds.width)
        let height = min(effectiveSize.height, bounds.height)
        guard width > lineWidth, height > lineWidth else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        let x = width - lineWidth / 2
        let y = height - lineWidth / 2
        if drawsVisibleAreaRightBorder {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: y))
        }
        if drawsVisibleAreaBottomBorder {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: x, y: y))
        }
        // Stroke the exact window-chrome separator color used by the pane outline,
        // sidebar trailing edge, and tab-bar separators (one source of truth), so the
        // iOS-connected viewport border is pixel-identical to every other border in the
        // app instead of the previous hardcoded near-white separator stroke.
        WindowChromeSeparatorColor.current().setStroke()
        path.stroke()
    }
}

final class GhosttySurfaceScrollView: NSView {
    enum FlashStyle {
        case navigation
        case notification
    }

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> FlashStyle {
        switch reason {
        case .navigation:
            return .navigation
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return .notification
        }
    }

    private static func flashPresentation(for style: FlashStyle) -> WorkspaceAttentionFlashPresentation {
        switch style {
        case .navigation:
            return WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        case .notification:
            return WorkspaceAttentionCoordinator.flashStyle(for: .notificationArrival)
        }
    }

    private enum NotificationRingMetrics {
        static let inset = PanelOverlayRingMetrics.inset
        static let cornerRadius = PanelOverlayRingMetrics.cornerRadius
        static let lineWidth = PanelOverlayRingMetrics.lineWidth
    }

    private var sharedBackdropCutoutView: NSView?
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let mobileViewportBorderOverlayView = TerminalViewportBorderOverlayView(frame: .zero)
    private let inactiveOverlayView: GhosttyFlashOverlayView
    private let dropZoneOverlayView: GhosttyFlashOverlayView
    private let paneDropTargetView = TerminalPaneDropTargetView(frame: .zero)
    private let notificationRingOverlayView: GhosttyFlashOverlayView
    private let notificationRingLayer: CAShapeLayer
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    var isRightSidebarDockSurface: Bool {
        surfaceView.terminalSurface?.focusPlacement == .rightSidebarDock
    }

    var uiWindow: NSWindow? {
        if let terminalSurface = surfaceView.terminalSurface {
            return terminalSurface.uiWindow
        }
        return window
    }

    func forwardKeyDownToSurface(_ event: NSEvent) {
        surfaceView.keyDown(with: event)
    }

    private var lastFlashStyle: FlashStyle = .navigation
    private let keyboardCopyModeBadgeContainerView: GhosttyFlashOverlayView
    private let keyboardCopyModeBadgeView: GhosttyPassthroughVisualEffectView
    private let keyboardCopyModeBadgeIconView: NSImageView
    private let keyboardCopyModeBadgeLabel: NSTextField
    private let imageTransferIndicatorContainerView: NSView
    private let imageTransferIndicatorView: NSVisualEffectView
    private let imageTransferIndicatorSpinner: NSProgressIndicator
    private let imageTransferCancelButton: NSButton
    private var searchOverlayHostingView: NSHostingView<SurfaceSearchOverlay>?
    private var deferredSearchOverlayMutationWorkItem: DispatchWorkItem?
    private var imageTransferIndicatorShowWorkItem: DispatchWorkItem?
    private var activeImageTransferOperation: TerminalImageTransferOperation?
    private var activeImageTransferCancelHandler: (() -> Void)?
    private var lastSearchOverlayStateID: ObjectIdentifier?
    private var searchOverlayMutationGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollbarTrackingArea: NSTrackingArea?
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    /// Tracks whether the user has scrolled away from the bottom to review scrollback.
    /// When true, auto-scroll should be suspended to prevent the "doomscroll" bug
    /// where the terminal fights the user's scroll position.
    private var userScrolledAwayFromBottom = false
    private var pendingExplicitWheelScroll = false
    private var allowExplicitScrollbarSync = false
    /// Threshold in points from bottom to consider "at bottom" (allows for minor float drift)
    private static let scrollToBottomThreshold: CGFloat = 5.0
    private var isActive = true
    private var lastFocusRefreshAt: CFTimeInterval = 0
    private var lastRequestedPortalOcclusionVisible: Bool?
    private var activeDropZone: DropZone?
    private var pendingDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var pendingAutomaticFirstResponderApply = false
    // Intentionally no focus retry loops: rely on AppKit first-responder and bonsplit selection.

    /// Tracks whether keyboard focus should go to the search field or the terminal
    /// when the window becomes key while the find bar is open.
    enum SearchFocusTarget {
        case searchField
        case terminal
    }
    private(set) var searchFocusTarget: SearchFocusTarget = .searchField


#if DEBUG
    private var lastDropZoneOverlayLogSignature: String?
    private var lastDragGeometryLogSignature: String?
    private var dragLayoutLogSequence: UInt64 = 0
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")
    private static var flashCounts: [UUID: Int] = [:]
    private static var drawCounts: [UUID: Int] = [:]
    private static var lastDrawTimes: [UUID: CFTimeInterval] = [:]
    private static var presentCounts: [UUID: Int] = [:]
    private static var dropOverlayShowCounts: [UUID: Int] = [:]
    private static var lastPresentTimes: [UUID: CFTimeInterval] = [:]
    private static var lastContentsKeys: [UUID: String] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }

    static func drawStats(for surfaceId: UUID) -> (count: Int, last: CFTimeInterval) {
        (drawCounts[surfaceId, default: 0], lastDrawTimes[surfaceId, default: 0])
    }

    static func resetDrawStats() {
        drawCounts.removeAll()
        lastDrawTimes.removeAll()
    }

    static func recordSurfaceDraw(_ surfaceId: UUID) {
        drawCounts[surfaceId, default: 0] += 1
        lastDrawTimes[surfaceId] = CACurrentMediaTime()
    }

    private static func contentsKey(for layer: CALayer?) -> String {
        guard let modelLayer = layer else { return "nil" }
        // Prefer the presentation layer to better reflect what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return "nil" }
        // Prefer pointer identity for object/CFType contents.
        if let obj = contents as AnyObject? {
            let ptr = Unmanaged.passUnretained(obj).toOpaque()
            var key = "0x" + String(UInt(bitPattern: ptr), radix: 16)

            // For IOSurface-backed terminal layers, the IOSurface object can remain stable while
            // its contents change. Include the IOSurface seed so "new frame rendered" is visible
            // to debug/test tooling even when the pointer identity doesn't change.
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                let surfaceRef = (contents as! IOSurfaceRef)
                let seed = IOSurfaceGetSeed(surfaceRef)
                key += ":seed=\(seed)"
            }

            return key
        }
        return String(describing: contents)
    }

    private static func updatePresentStats(surfaceId: UUID, layer: CALayer?) -> (count: Int, last: CFTimeInterval, key: String) {
        let key = contentsKey(for: layer)
        if lastContentsKeys[surfaceId] != key {
            presentCounts[surfaceId, default: 0] += 1
            lastPresentTimes[surfaceId] = CACurrentMediaTime()
            lastContentsKeys[surfaceId] = key
        }
        return (presentCounts[surfaceId, default: 0], lastPresentTimes[surfaceId, default: 0], key)
    }

    private func recordDropOverlayShowAnimation() {
        guard let surfaceId = surfaceView.terminalSurface?.id else { return }
        Self.dropOverlayShowCounts[surfaceId, default: 0] += 1
    }

    func debugProbeDropOverlayAnimation(useDeferredPath: Bool) -> (before: Int, after: Int, bounds: CGSize) {
        guard let surfaceId = surfaceView.terminalSurface?.id else {
            return (0, 0, bounds.size)
        }

        let before = Self.dropOverlayShowCounts[surfaceId, default: 0]

        // Reset to a hidden baseline so each probe exercises an initial-show transition.
        dropZoneOverlayAnimationGeneration &+= 1
        activeDropZone = nil
        pendingDropZone = nil
        dropZoneOverlayView.layer?.removeAllAnimations()
        dropZoneOverlayView.isHidden = true
        dropZoneOverlayView.alphaValue = 1

        if useDeferredPath {
            pendingDropZone = .left
            synchronizeGeometryAndContent()
        } else {
            setDropZoneOverlay(zone: .left)
        }

        let after = Self.dropOverlayShowCounts[surfaceId, default: 0]
        setDropZoneOverlay(zone: nil)
        return (before, after, bounds.size)
    }

    var debugSurfaceId: UUID? {
        surfaceView.terminalSurface?.id
    }

    var debugCellSize: CGSize {
        surfaceView.cellSize
    }

    private func debugPointInSurface(_ point: NSPoint) -> NSPoint {
        surfaceView.convert(point, from: self)
    }

    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        surfaceView.debugSimulateSelection(
            from: debugPointInSurface(startPoint),
            to: debugPointInSurface(endPoint)
        )
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        surfaceView.debugSimulateCommandHover(at: debugPointInSurface(point))
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandHoverDetails(at: debugPointInSurface(point))
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandClick(at: debugPointInSurface(point))
    }
#endif

    func portalBindingGuardState() -> (surfaceId: UUID?, generation: UInt64?, state: String) {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return (surfaceId: nil, generation: nil, state: "missingSurface")
        }
        return (
            surfaceId: terminalSurface.id,
            generation: terminalSurface.portalBindingGeneration(),
            state: terminalSurface.portalBindingStateLabel()
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        )
    }

    func releaseOwnedPortalHost(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.releasePortalHostIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    func prepareOwnedPortalHostForTransientReattach(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.preparePortalHostReplacementIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    init(surfaceView: GhosttyNSView) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        inactiveOverlayView = GhosttyFlashOverlayView(frame: .zero)
        dropZoneOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingLayer = CAShapeLayer()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        keyboardCopyModeBadgeContainerView = GhosttyFlashOverlayView(frame: .zero)
        keyboardCopyModeBadgeView = GhosttyPassthroughVisualEffectView(frame: .zero)
        keyboardCopyModeBadgeIconView = NSImageView(frame: .zero)
        keyboardCopyModeBadgeLabel = NSTextField(labelWithString: terminalKeyboardCopyModeIndicatorText)
        imageTransferIndicatorContainerView = NSView(frame: .zero)
        imageTransferIndicatorView = NSVisualEffectView(frame: .zero)
        imageTransferIndicatorSpinner = NSProgressIndicator(frame: .zero)
        imageTransferCancelButton = NSButton(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundView.layer?.isOpaque = false
        addSubview(backgroundView)
        addSubview(scrollView)
        mobileViewportBorderOverlayView.isHidden = true
        addSubview(mobileViewportBorderOverlayView, positioned: .above, relativeTo: scrollView)
        paneDropTargetView.hostedView = self
        addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        synchronizeScrollbarAppearance()
        inactiveOverlayView.wantsLayer = true
        inactiveOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        inactiveOverlayView.isHidden = true
        addSubview(inactiveOverlayView)
        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        let notificationRingStyle = WorkspaceAttentionCoordinator.notificationRingStyle
        let notificationRingColor = notificationRingStyle.accent.strokeColor
        notificationRingLayer.fillColor = NSColor.clear.cgColor
        notificationRingLayer.strokeColor = notificationRingColor.cgColor
        notificationRingLayer.lineWidth = NotificationRingMetrics.lineWidth
        notificationRingLayer.lineJoin = .round
        notificationRingLayer.lineCap = .round
        notificationRingLayer.shadowColor = notificationRingColor.cgColor
        notificationRingLayer.shadowOpacity = Float(notificationRingStyle.glowOpacity)
        notificationRingLayer.shadowRadius = notificationRingStyle.glowRadius
        notificationRingLayer.shadowOffset = .zero
        notificationRingLayer.opacity = 0
        notificationRingOverlayView.layer?.addSublayer(notificationRingLayer)
        notificationRingOverlayView.isHidden = true
        addSubview(notificationRingOverlayView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        let flashStyle = WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        let flashColor = flashStyle.accent.strokeColor
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = flashColor.cgColor
        flashLayer.lineWidth = NotificationRingMetrics.lineWidth
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = flashColor.cgColor
        flashLayer.shadowOpacity = Float(flashStyle.glowOpacity)
        flashLayer.shadowRadius = flashStyle.glowRadius
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)
        keyboardCopyModeBadgeContainerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeContainerView.wantsLayer = true
        keyboardCopyModeBadgeContainerView.layer?.masksToBounds = false
        keyboardCopyModeBadgeContainerView.layer?.shadowColor = NSColor.black.cgColor
        keyboardCopyModeBadgeContainerView.layer?.shadowOpacity = 0.22
        keyboardCopyModeBadgeContainerView.layer?.shadowRadius = 10
        keyboardCopyModeBadgeContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        keyboardCopyModeBadgeView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeView.wantsLayer = true
        keyboardCopyModeBadgeView.material = .hudWindow
        keyboardCopyModeBadgeView.blendingMode = .withinWindow
        keyboardCopyModeBadgeView.state = .active
        keyboardCopyModeBadgeView.layer?.cornerRadius = 18
        keyboardCopyModeBadgeView.layer?.masksToBounds = true
        keyboardCopyModeBadgeView.layer?.borderWidth = 1
        keyboardCopyModeBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        keyboardCopyModeBadgeView.alphaValue = 0.97
        keyboardCopyModeBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeIconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular,
            scale: .medium
        )
        keyboardCopyModeBadgeIconView.image = NSImage(
            systemSymbolName: "keyboard.badge.ellipsis",
            accessibilityDescription: terminalKeyTableIndicatorAccessibilityLabel
        )
        keyboardCopyModeBadgeIconView.contentTintColor = NSColor.secondaryLabelColor
        keyboardCopyModeBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeLabel.textColor = NSColor.labelColor
        keyboardCopyModeBadgeLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        keyboardCopyModeBadgeLabel.lineBreakMode = .byTruncatingTail
        keyboardCopyModeBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeContainerView.addSubview(keyboardCopyModeBadgeView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeIconView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeLabel)
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeView.topAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.topAnchor),
            keyboardCopyModeBadgeView.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor),
            keyboardCopyModeBadgeView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.leadingAnchor),
            keyboardCopyModeBadgeView.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.trailingAnchor),
            keyboardCopyModeBadgeView.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            keyboardCopyModeBadgeIconView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.leadingAnchor, constant: 12),
            keyboardCopyModeBadgeIconView.centerYAnchor.constraint(equalTo: keyboardCopyModeBadgeView.centerYAnchor),
            keyboardCopyModeBadgeIconView.widthAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeIconView.heightAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeLabel.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeIconView.trailingAnchor, constant: 7),
            keyboardCopyModeBadgeLabel.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.trailingAnchor, constant: -14),
            keyboardCopyModeBadgeLabel.topAnchor.constraint(equalTo: keyboardCopyModeBadgeView.topAnchor, constant: 8),
            keyboardCopyModeBadgeLabel.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeView.bottomAnchor, constant: -8),
        ])
        keyboardCopyModeBadgeContainerView.isHidden = true
        addSubview(keyboardCopyModeBadgeContainerView)
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeContainerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            keyboardCopyModeBadgeContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        imageTransferIndicatorContainerView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorContainerView.wantsLayer = true
        imageTransferIndicatorContainerView.layer?.masksToBounds = false
        imageTransferIndicatorContainerView.layer?.shadowColor = NSColor.black.cgColor
        imageTransferIndicatorContainerView.layer?.shadowOpacity = 0.18
        imageTransferIndicatorContainerView.layer?.shadowRadius = 8
        imageTransferIndicatorContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        imageTransferIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorView.wantsLayer = true
        imageTransferIndicatorView.material = .hudWindow
        imageTransferIndicatorView.blendingMode = .withinWindow
        imageTransferIndicatorView.state = .active
        imageTransferIndicatorView.layer?.cornerRadius = 16
        imageTransferIndicatorView.layer?.masksToBounds = true
        imageTransferIndicatorView.layer?.borderWidth = 1
        imageTransferIndicatorView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        imageTransferIndicatorView.alphaValue = 0.95
        imageTransferIndicatorSpinner.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorSpinner.style = .spinning
        imageTransferIndicatorSpinner.controlSize = .small
        imageTransferIndicatorSpinner.isDisplayedWhenStopped = false
        imageTransferCancelButton.translatesAutoresizingMaskIntoConstraints = false
        imageTransferCancelButton.isBordered = false
        imageTransferCancelButton.imagePosition = .imageOnly
        imageTransferCancelButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.contentTintColor = NSColor.secondaryLabelColor
        imageTransferCancelButton.toolTip = String(localized: "common.cancel", defaultValue: "Cancel")
        imageTransferCancelButton.setAccessibilityLabel(
            String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.target = self
        imageTransferCancelButton.action = #selector(handleImageTransferCancel)
        imageTransferIndicatorContainerView.addSubview(imageTransferIndicatorView)
        imageTransferIndicatorView.addSubview(imageTransferIndicatorSpinner)
        imageTransferIndicatorView.addSubview(imageTransferCancelButton)
        NSLayoutConstraint.activate([
            imageTransferIndicatorView.topAnchor.constraint(equalTo: imageTransferIndicatorContainerView.topAnchor),
            imageTransferIndicatorView.bottomAnchor.constraint(equalTo: imageTransferIndicatorContainerView.bottomAnchor),
            imageTransferIndicatorView.leadingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.leadingAnchor),
            imageTransferIndicatorView.trailingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.trailingAnchor),
            imageTransferIndicatorSpinner.leadingAnchor.constraint(equalTo: imageTransferIndicatorView.leadingAnchor, constant: 10),
            imageTransferIndicatorSpinner.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferIndicatorSpinner.widthAnchor.constraint(equalToConstant: 14),
            imageTransferIndicatorSpinner.heightAnchor.constraint(equalToConstant: 14),
            imageTransferCancelButton.leadingAnchor.constraint(equalTo: imageTransferIndicatorSpinner.trailingAnchor, constant: 6),
            imageTransferCancelButton.trailingAnchor.constraint(equalTo: imageTransferIndicatorView.trailingAnchor, constant: -8),
            imageTransferCancelButton.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferCancelButton.widthAnchor.constraint(equalToConstant: 16),
            imageTransferCancelButton.heightAnchor.constraint(equalToConstant: 16),
            imageTransferIndicatorSpinner.topAnchor.constraint(equalTo: imageTransferIndicatorView.topAnchor, constant: 8),
            imageTransferIndicatorSpinner.bottomAnchor.constraint(equalTo: imageTransferIndicatorView.bottomAnchor, constant: -8),
        ])
        imageTransferIndicatorContainerView.isHidden = true
        addSubview(imageTransferIndicatorContainerView)
        NSLayoutConstraint.activate([
            imageTransferIndicatorContainerView.topAnchor.constraint(
                equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor,
                constant: 8
            ),
            imageTransferIndicatorContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
            // Final scroll position check to update userScrolledAwayFromBottom state
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let readySurfaceId = notification.userInfo?["surfaceId"] as? UUID,
                  readySurfaceId == self.surfaceView.terminalSurface?.id else {
                return
            }
            // Session restore can request focus before the runtime surface exists.
            // Re-run the normal first-responder/focus path once the surface is live.
            guard self.isActive || self.surfaceView.desiredFocus || self.isSurfaceViewFirstResponder() else {
                return
            }
            self.scheduleAutomaticFirstResponderApply(reason: "surfaceDidBecomeReady")
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidReceiveWheelScroll,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.pendingExplicitWheelScroll = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySearchFocus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surface = notification.object as? TerminalSurface,
                  surface === self.surfaceView.terminalSurface else { return }
            self.searchFocusTarget = .searchField
            // Explicitly unfocus the terminal so the cursor stops blinking
            // when the search field takes over.
            surface.setFocus(false)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            // Match AppKit's geometry change immediately so the terminal width
            // does not stay stuck behind a legacy scrollbar gutter.
            queue: nil
        ) { [weak self] _ in
            self?.handlePreferredScrollerStyleChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: TerminalScrollBarSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTerminalScrollBarPreferenceChange()
        })

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
#if DEBUG
        cmuxDebugLog(
            "surface.hosted.deinit surface=\(debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0) " +
            "hidden=\(isHidden ? 1 : 0) frame=\(String(format: "%.1fx%.1f", frame.width, frame.height))"
        )
#endif
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deferredSearchOverlayMutationWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem?.cancel()
        dropZoneOverlayView.removeFromSuperview()
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard scrollView.hasVerticalScroller,
              NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        if let scrollbarTrackingArea {
            removeTrackingArea(scrollbarTrackingArea)
            self.scrollbarTrackingArea = nil
        }

        super.updateTrackingAreas()

        guard scrollView.hasVerticalScroller,
              let scroller = scrollView.verticalScroller else { return }

        let trackingArea = NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        synchronizeGeometryAndContent()
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        bringPaneDropTargetToFrontIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard activeDropZone != nil || pendingDropZone != nil else { return }
        attachDropZoneOverlayIfNeeded()
        if let zone = activeDropZone ?? pendingDropZone {
            applyDropZoneOverlayFrame(dropZoneOverlayFrame(for: zone, in: bounds.size))
        }
    }

    /// Reconcile AppKit geometry with ghostty surface geometry synchronously.
    /// Used after split topology mutations (close/split) to prevent a stale one-frame
    /// IOSurface size from being presented after pane expansion.
    @discardableResult
    func reconcileGeometryNow() -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileGeometryNow()
            }
            return false
        }

        return synchronizeGeometryAndContent()
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow(reason: String = "portal.refreshSurfaceNow") {
        // Portal reparent/reveal can settle geometry a tick before AppKit finishes
        // realizing the terminal subtree's backing layer state. Flush display for the
        // hosted subtree first so forceRefresh does not race a still-unrealized layer.
        layoutSubtreeIfNeeded()
        surfaceView.layoutSubtreeIfNeeded()
        displayIfNeeded()
        surfaceView.displayIfNeeded()
        surfaceView.terminalSurface?.forceRefresh(reason: reason)
    }

    @discardableResult
    private func synchronizeGeometryAndContent() -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let didScrollbarAppearanceChange = synchronizeScrollbarAppearance()
        let previousSurfaceSize = surfaceView.frame.size
        if let sharedBackdropCutoutView {
            _ = setFrameIfNeeded(sharedBackdropCutoutView, to: bounds)
        }
        _ = setFrameIfNeeded(backgroundView, to: bounds)
        _ = setFrameIfNeeded(scrollView, to: bounds)
        let targetSize = scrollView.bounds.size
#if DEBUG
        logLayoutDuringActiveDrag(targetSize: targetSize)
#endif
        let targetSurfaceFrame = CGRect(origin: surfaceView.frame.origin, size: targetSize)
        _ = setFrameIfNeeded(surfaceView, to: targetSurfaceFrame)
        let targetDocumentFrame = CGRect(
            origin: documentView.frame.origin,
            size: CGSize(width: scrollView.bounds.width, height: documentView.frame.height)
        )
        _ = setFrameIfNeeded(documentView, to: targetDocumentFrame)
        _ = setFrameIfNeeded(mobileViewportBorderOverlayView, to: bounds)
        _ = setFrameIfNeeded(inactiveOverlayView, to: bounds)
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        if let zone = activeDropZone {
            attachDropZoneOverlayIfNeeded()
            _ = setFrameIfNeeded(
                dropZoneOverlayView,
                to: dropZoneOverlayFrame(for: zone, in: bounds.size)
            )
        }
        if let pending = pendingDropZone,
           bounds.width > 2,
           bounds.height > 2 {
            pendingDropZone = nil
#if DEBUG
            let frame = dropZoneOverlayFrame(for: pending, in: bounds.size)
            logDropZoneOverlay(event: "flushPending", zone: pending, frame: frame)
#endif
            // Reuse the normal show/update path so deferred overlays get the
            // same initial animation as direct drop-zone activation.
            setDropZoneOverlay(zone: pending)
        }
        _ = setFrameIfNeeded(notificationRingOverlayView, to: bounds)
        _ = setFrameIfNeeded(flashOverlayView, to: bounds)
        if let overlay = searchOverlayHostingView {
            _ = setFrameIfNeeded(overlay, to: bounds)
        }
        bringPaneDropTargetToFrontIfNeeded()
        // NSScrollView can defer clip-view/content-size updates until its own layout pass,
        // which makes interactive width changes arrive a queue turn late on Sequoia.
        if didScrollbarAppearanceChange {
            scrollView.tile()
        }
        scrollView.layoutSubtreeIfNeeded()
        updateNotificationRingPath()
        updateFlashPath(style: lastFlashStyle)
        updateFlashAppearance(style: lastFlashStyle)
        synchronizeScrollView()
        synchronizeSurfaceView()
        let didCoreSurfaceChange = synchronizeCoreSurface()
        return !sizeApproximatelyEqual(previousSurfaceSize, targetSize) || didCoreSurfaceChange
    }

    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {
        let isVisible = drawRight || drawBottom
        mobileViewportBorderOverlayView.effectiveSize = size
        mobileViewportBorderOverlayView.drawsVisibleAreaBorder = isVisible
        mobileViewportBorderOverlayView.drawsVisibleAreaRightBorder = drawRight
        mobileViewportBorderOverlayView.drawsVisibleAreaBottomBorder = drawBottom
        mobileViewportBorderOverlayView.isHidden = !isVisible
    }

    @discardableResult
    private func setFrameIfNeeded(_ view: NSView, to frame: CGRect) -> Bool {
        guard !Self.rectApproximatelyEqual(view.frame, frame) else { return false }
        view.frame = frame
        return true
    }

    private func sizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    private func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private func dropZoneOverlayContainerView() -> NSView {
        superview ?? self
    }

    private func bringPaneDropTargetToFrontIfNeeded() {
        if paneDropTargetView.superview !== self || subviews.last !== paneDropTargetView {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
    }

    private func attachDropZoneOverlayIfNeeded() {
        // Keep the hover indicator outside the hosted terminal subtree so it stays purely additive
        // and cannot invalidate the scroll/surface layout that Ghostty renders into.
        let container = dropZoneOverlayContainerView()
        if dropZoneOverlayView.superview !== container {
            dropZoneOverlayView.removeFromSuperview()
            if container === self {
                addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
            } else {
                container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
            }
#if DEBUG
            logDropZoneOverlay(event: "attach", zone: activeDropZone ?? pendingDropZone, frame: dropZoneOverlayView.frame)
#endif
            return
        }

        guard container !== self else { return }
        guard let hostedIndex = container.subviews.firstIndex(of: self),
              let overlayIndex = container.subviews.firstIndex(of: dropZoneOverlayView),
              overlayIndex <= hostedIndex else { return }
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
    }

    private func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

#if DEBUG
    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func hasActiveDragLoggingContext() -> Bool {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        return activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
    }

    private func logDragGeometryChange(event: String, old: CGPoint, new: CGPoint) {
        guard hasActiveDragLoggingContext() else { return }

        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let signature =
            "\(event)|\(surface)|\(String(format: "%.1f,%.1f", old.x, old.y))|" +
            "\(String(format: "%.1f,%.1f", new.x, new.y))|\(overlaySuperviewClass)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDragGeometryLogSignature != signature else { return }
        lastDragGeometryLogSignature = signature
        cmuxDebugLog(
            "terminal.dragGeometry event=\(event) surface=\(surface) " +
            "old=\(String(format: "%.1f,%.1f", old.x, old.y)) " +
            "new=\(String(format: "%.1f,%.1f", new.x, new.y)) " +
            "overlaySuper=\(overlaySuperviewClass) " +
            "overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "overlayHidden=\(dropZoneOverlayView.isHidden ? 1 : 0)"
        )
    }

    private func logLayoutDuringActiveDrag(targetSize: CGSize) {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        let hasActiveDrag =
            activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
        guard hasActiveDrag else { return }

        dragLayoutLogSequence &+= 1
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let activeZone = activeDropZone.map { String(describing: $0) } ?? "none"
        let pendingZone = pendingDropZone.map { String(describing: $0) } ?? "none"
        let event = eventType.map { String(describing: $0) } ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "terminal.layout.drag surface=\(surface) seq=\(dragLayoutLogSequence) " +
            "activeZone=\(activeZone) pendingZone=\(pendingZone) " +
            "hasTabDrag=\(hasTabDrag ? 1 : 0) hasSidebarDrag=\(hasSidebarDrag ? 1 : 0) " +
            "event=\(event) inWindow=\(window != nil ? 1 : 0) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(String(format: "%.1f,%.1f", scrollView.contentView.bounds.origin.x, scrollView.contentView.bounds.origin.y)) " +
            "surfaceOrigin=\(String(format: "%.1f,%.1f", surfaceView.frame.origin.x, surfaceView.frame.origin.y)) " +
            "bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "target=\(String(format: "%.1fx%.1f", targetSize.width, targetSize.height))"
        )
    }
#endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, self.surfaceView.isVisibleInUI, let tabId = self.surfaceView.tabId, let surfaceId = self.surfaceView.terminalSurface?.id, self.matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: surfaceId) else { return }
#if DEBUG
            cmuxDebugLog("find.window.didBecomeKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(self.surfaceView.terminalSurface?.searchState != nil) focusTarget=\(self.searchFocusTarget) firstResponder=\(String(describing: self.window?.firstResponder))")
#endif
            self.scheduleAutomaticFirstResponderApply(reason: "didBecomeKey")
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let searchActive = self.surfaceView.terminalSurface?.searchState != nil
            // Losing key window does not always trigger first-responder resignation, so force
            // the focused terminal view to yield responder to keep Ghostty cursor/focus state in sync.
            if let fr = window.firstResponder as? NSView,
               fr === self.surfaceView || fr.isDescendant(of: self.surfaceView) {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) resigningFirstResponder")
#endif
                window.makeFirstResponder(nil)
            } else {
#if DEBUG
                cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) firstResponder=\(String(describing: window.firstResponder)) (not terminal, skipping)")
#endif
            }
        })
        if window.isKeyWindow {
            scheduleAutomaticFirstResponderApply(reason: "viewDidMoveToWindow")
        }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
        // Preserve the bootstrap 800x600 surface until portal reattach churn
        // has produced a real host size instead of a transient 1x1 placeholder.
        guard bounds.width > 1, bounds.height > 1 else { return }
        _ = synchronizeGeometryAndContent()
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        guard let handler else {
            surfaceView.onFocus = nil
            return
        }
        surfaceView.onFocus = { [weak self] in
            // When the terminal surface gains focus (click, tab, etc.), update the
            // search focus target so window reactivation restores terminal focus.
            if self?.surfaceView.terminalSurface?.searchState != nil {
                self?.searchFocusTarget = .terminal
            }
            handler()
        }
    }

    func beginFindEscapeSuppression() {
        surfaceView.beginFindEscapeSuppression()
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    /// Applies the host-layer terminal fill and optionally clears the shared backdrop behind it.
    func setBackgroundColor(_ color: NSColor, clearsSharedWindowBackdrop: Bool = false) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        synchronizeSharedBackdropCutout(visible: clearsSharedWindowBackdrop)
        layer.backgroundColor = color.cgColor
        layer.isOpaque = color.alphaComponent >= 1.0
        CATransaction.commit()
        // The viewport border strokes the window-chrome separator color, which tracks the
        // terminal background/theme. Repaint it when the background changes (e.g. theme
        // switch) so a connected iOS device's visible-area border stays in sync.
        if !mobileViewportBorderOverlayView.isHidden {
            mobileViewportBorderOverlayView.needsDisplay = true
        }
    }

    /// Keeps the shared-backdrop cutout view present only while a pane-local fill needs it.
    private func synchronizeSharedBackdropCutout(visible: Bool) {
        if visible {
            let cutoutView = sharedBackdropCutoutView ?? makeSharedBackdropCutoutView()
            _ = setFrameIfNeeded(cutoutView, to: bounds)
            return
        }

        sharedBackdropCutoutView?.removeFromSuperview()
        sharedBackdropCutoutView = nil
    }

    /// Creates the Core Image filtered view that subtracts pane-local fills from shared backdrop.
    ///
    /// AppKit requires `layerUsesCoreImageFilters` to be configured before display, so the
    /// cutout view is created lazily only when a pane-local OSC background override needs it.
    private func makeSharedBackdropCutoutView() -> NSView {
        let sharedBackdropCutoutFilter = TerminalSharedBackdropCutoutFilter()
        sharedBackdropCutoutFilter.name = "terminalSharedBackdropCutout"
        let cutoutView = NSView(frame: bounds)
        cutoutView.wantsLayer = true
        cutoutView.layerUsesCoreImageFilters = true
        cutoutView.compositingFilter = sharedBackdropCutoutFilter
        cutoutView.layer?.backgroundColor = NSColor.white.cgColor
        cutoutView.layer?.isOpaque = true
        addSubview(cutoutView, positioned: .below, relativeTo: backgroundView)
        sharedBackdropCutoutView = cutoutView
        return cutoutView
    }

    func setInactiveOverlay(color: NSColor, opacity: CGFloat, visible: Bool) {
        let clampedOpacity = max(0, min(1, opacity))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inactiveOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedOpacity).cgColor
        inactiveOverlayView.isHidden = !(visible && clampedOpacity > 0.0001)
        CATransaction.commit()
    }

    func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        let targetHidden = !visible
        let targetOpacity: Float = visible ? 1 : 0
        guard notificationRingOverlayView.isHidden != targetHidden ||
                notificationRingLayer.opacity != targetOpacity else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = targetHidden
        notificationRingLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    private func cancelDeferredSearchOverlayMutation() {
        deferredSearchOverlayMutationWorkItem?.cancel()
        deferredSearchOverlayMutationWorkItem = nil
    }

    private func scheduleDeferredSearchOverlayMutation(
        generation: UInt64,
        _ mutation: @escaping () -> Void
    ) {
        cancelDeferredSearchOverlayMutation()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.searchOverlayMutationGeneration == generation else { return }
            self.deferredSearchOverlayMutationWorkItem = nil
            mutation()
        }
        deferredSearchOverlayMutationWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func cancelImageTransferIndicatorShow() {
        imageTransferIndicatorShowWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem = nil
    }

    private func updateImageTransferIndicatorZOrder(relativeTo overlay: NSView?) {
        guard !imageTransferIndicatorContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: overlay)
            return
        }
        if keyboardCopyModeBadgeContainerView.superview === self,
           !keyboardCopyModeBadgeContainerView.isHidden {
            addSubview(
                imageTransferIndicatorContainerView,
                positioned: .above,
                relativeTo: keyboardCopyModeBadgeContainerView
            )
            return
        }
        addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: nil)
    }

    private func updateKeyboardCopyModeBadgeZOrder(relativeTo overlay: NSView?) {
        guard !keyboardCopyModeBadgeContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: overlay)
        } else {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: nil)
        }
        updateImageTransferIndicatorZOrder(relativeTo: overlay)
    }

    @objc private func handleImageTransferCancel() {
        guard let operation = activeImageTransferOperation else { return }
        let onCancel = activeImageTransferCancelHandler
        guard operation.cancel() else { return }
        endImageTransferIndicator(for: operation)
        onCancel?()
    }

    func beginImageTransferIndicator(
        for operation: TerminalImageTransferOperation,
        onCancel: @escaping () -> Void
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginImageTransferIndicator(for: operation, onCancel: onCancel)
            }
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = operation
        activeImageTransferCancelHandler = onCancel
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeImageTransferOperation === operation else { return }
            guard !operation.isCancelled else { return }
            self.imageTransferIndicatorShowWorkItem = nil
            self.imageTransferIndicatorSpinner.startAnimation(nil)
            self.imageTransferIndicatorContainerView.isHidden = false
            self.updateImageTransferIndicatorZOrder(relativeTo: self.searchOverlayHostingView)
        }
        imageTransferIndicatorShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func endImageTransferIndicator(for operation: TerminalImageTransferOperation?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.endImageTransferIndicator(for: operation)
            }
            return
        }

        if let operation,
           activeImageTransferOperation !== operation {
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = nil
        activeImageTransferCancelHandler = nil
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true
    }

    private func makeSearchOverlayRootView(
        terminalSurface: TerminalSurface,
        searchState: TerminalSurface.SearchState
    ) -> SurfaceSearchOverlay {
        SurfaceSearchOverlay(
            tabId: terminalSurface.tabId,
            surfaceId: terminalSurface.id,
            searchState: searchState,
            canApplyFocusRequest: { [weak self] in
                self?.canApplyMountedSearchFieldFocusRequest() ?? false
            },
            onNavigateSearch: { [weak terminalSurface] action in
                _ = terminalSurface?.performBindingAction(action)
            },
            onFieldDidFocus: { [weak self, weak terminalSurface] in
                self?.searchFocusTarget = .searchField
                terminalSurface?.setFocus(false)
            },
            onClose: { [weak self, weak terminalSurface] in
                terminalSurface?.searchState = nil
                self?.moveFocus()
            }
        )
    }

    private func findEditableSearchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableSearchField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func mountedSearchFieldIfAvailable() -> NSTextField? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return findEditableSearchField(in: overlay)
    }

    private func mountedSearchFieldOwnsResponder(
        _ responder: NSResponder?,
        field: NSTextField? = nil
    ) -> Bool {
        guard let responder else { return false }
        guard let field = field ?? mountedSearchFieldIfAvailable() else { return false }
        return responder === field || field.currentEditor() === responder
    }

    private func resolvedKeyboardFocusOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        let mountedSearchField = mountedSearchFieldIfAvailable()
        if mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField
        }

        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            var current = editor.nextResponder
            while let next = current {
                if let view = next as? NSView {
                    return view
                }
                current = next.nextResponder
            }
            return editor.superview ?? editor
        }

        return responder as? NSView
    }

    private func canApplyMountedSearchFieldFocusRequest() -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: terminalSurface.tabId),
              manager.selectedTabId == terminalSurface.tabId,
              let workspace = manager.tabs.first(where: { $0.id == terminalSurface.tabId }) else {
            return false
        }
        return workspace.focusedPanelId == terminalSurface.id
    }

    private func requestMountedSearchFieldFocus(
        generation: UInt64,
        force: Bool,
        attemptsRemaining: Int = 4
    ) {
        guard searchOverlayMutationGeneration == generation else { return }
        guard force || searchFocusTarget == .searchField else { return }
        guard canApplyMountedSearchFieldFocusRequest() else { return }
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self,
              let window,
              window.isKeyWindow else { return }

        guard let field = findEditableSearchField(in: overlay) else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.requestMountedSearchFieldFocus(
                    generation: generation,
                    force: force,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)
        guard !alreadyFocused else { return }

        surfaceView.terminalSurface?.setFocus(false)
        let result = window.makeFirstResponder(field)
#if DEBUG
        cmuxDebugLog(
            "find.mountedFieldFocus surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "result=\(result ? 1 : 0) attemptsRemaining=\(attemptsRemaining) " +
            "firstResponder=\(String(describing: window.firstResponder))"
        )
#endif
        guard !result, attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.requestMountedSearchFieldFocus(
                generation: generation,
                force: force,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    func setSearchOverlay(searchState: TerminalSurface.SearchState?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setSearchOverlay(searchState: searchState)
            }
            return
        }

        searchOverlayMutationGeneration &+= 1
        let mutationGeneration = searchOverlayMutationGeneration

        // Layering contract: keep terminal Cmd+F UI inside this portal-hosted AppKit view.
        // SwiftUI panel-level overlays can fall behind portal-hosted terminal surfaces.
        guard let terminalSurface = surfaceView.terminalSurface,
              let searchState else {
            let hadOverlay = searchOverlayHostingView != nil
            lastSearchOverlayStateID = nil
            searchFocusTarget = .searchField
            guard hadOverlay else {
                cancelDeferredSearchOverlayMutation()
                return
            }
#if DEBUG
            cmuxDebugLog("find.setSearchOverlay REMOVE surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") hadOverlay=\(hadOverlay)")
#endif
            scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self] in
                self?.searchOverlayHostingView?.removeFromSuperview()
                self?.searchOverlayHostingView = nil
            }
            return
        }

        let searchStateID = ObjectIdentifier(searchState)
        if let overlay = searchOverlayHostingView,
           lastSearchOverlayStateID == searchStateID,
           overlay.superview === self {
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        let hadOverlay = searchOverlayHostingView != nil
#if DEBUG
        cmuxDebugLog("find.setSearchOverlay MOUNT surface=\(terminalSurface.id.uuidString.prefix(5)) existingOverlay=\(hadOverlay ? "yes(update)" : "no(create)")")
#endif

        let rootView = makeSearchOverlayRootView(
            terminalSurface: terminalSurface,
            searchState: searchState
        )

        if let overlay = searchOverlayHostingView {
            overlay.rootView = rootView
            lastSearchOverlayStateID = searchStateID
            if overlay.superview !== self {
                scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    overlay.removeFromSuperview()
                    overlay.frame = self.bounds
                    overlay.autoresizingMask = [.width, .height]
                    self.addSubview(overlay)
                    self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
                    self.requestMountedSearchFieldFocus(
                        generation: mutationGeneration,
                        force: false
                    )
                }
                return
            }
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        searchFocusTarget = .searchField
        let overlay = TerminalSearchOverlayHostingView(rootView: rootView, surfaceView: surfaceView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        searchOverlayHostingView = overlay
        lastSearchOverlayStateID = searchStateID
        scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            guard self.searchOverlayHostingView === overlay else { return }
            overlay.removeFromSuperview()
            overlay.frame = self.bounds
            overlay.autoresizingMask = [.width, .height]
            self.addSubview(overlay)
            self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            self.requestMountedSearchFieldFocus(
                generation: mutationGeneration,
                force: true
            )
        }
    }

    func syncKeyStateIndicator(text: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.syncKeyStateIndicator(text: text)
            }
            return
        }

        if let text, !text.isEmpty {
            keyboardCopyModeBadgeLabel.stringValue = text
            keyboardCopyModeBadgeIconView.setAccessibilityLabel(text)
            let needsReorder = keyboardCopyModeBadgeContainerView.isHidden
                || keyboardCopyModeBadgeContainerView.superview !== self
                || subviews.last !== keyboardCopyModeBadgeContainerView
            keyboardCopyModeBadgeContainerView.isHidden = false
            if needsReorder {
                updateKeyboardCopyModeBadgeZOrder(relativeTo: searchOverlayHostingView)
            }
            return
        }

        keyboardCopyModeBadgeIconView.setAccessibilityLabel(terminalKeyTableIndicatorAccessibilityLabel)
        keyboardCopyModeBadgeContainerView.isHidden = true
    }

    func refreshHostBackgroundAfterGhosttyConfigReload() {
        _ = synchronizeGeometryAndContent()
        surfaceView.applySurfaceBackground()
        surfaceView.applyWindowBackgroundIfActive()
    }

    func reapplySurfaceColorSchemeAfterGhosttyConfigReload(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        surfaceView.applySurfaceColorScheme(
            force: true,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = PaneDropRouting.compactOverlayFrame(for: zone, in: size)

        let container = dropZoneOverlayView.superview ?? superview
        guard let container, container !== self else { return localFrame }
        return container.convert(localFrame, from: self)
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone)
            }
            return
        }

        if let zone, (bounds.width <= 2 || bounds.height <= 2) {
            pendingDropZone = zone
#if DEBUG
            logDropZoneOverlay(event: "deferZeroBounds", zone: zone, frame: nil)
#endif
            return
        }

        let previousZone = activeDropZone
        activeDropZone = zone
        pendingDropZone = nil

        if let zone {
#if DEBUG
            if window == nil {
                logDropZoneOverlay(event: "showNoWindow", zone: zone, frame: nil)
            }
#endif
            attachDropZoneOverlayIfNeeded()
            let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
            let previousFrame = dropZoneOverlayView.frame
            let isSameFrame = Self.rectApproximatelyEqual(previousFrame, targetFrame)
            let needsFrameUpdate = !isSameFrame
            let zoneChanged = previousZone != zone

            if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            dropZoneOverlayView.layer?.removeAllAnimations()

            if dropZoneOverlayView.isHidden {
                applyDropZoneOverlayFrame(targetFrame)
                dropZoneOverlayView.alphaValue = 0
                dropZoneOverlayView.isHidden = false
#if DEBUG
                recordDropOverlayShowAnimation()
#endif
#if DEBUG
                logDropZoneOverlay(event: "show", zone: zone, frame: targetFrame)
#endif

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dropZoneOverlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
#if DEBUG
                    guard let self else { return }
                    guard self.activeDropZone == zone else { return }
                    self.logDropZoneOverlay(event: "showComplete", zone: zone, frame: targetFrame)
#endif
                }
                return
            }

#if DEBUG
            if needsFrameUpdate || zoneChanged {
                logDropZoneOverlay(event: "update", zone: zone, frame: targetFrame)
            }
#endif
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if needsFrameUpdate {
                    dropZoneOverlayView.animator().frame = targetFrame
                }
                if dropZoneOverlayView.alphaValue < 1 {
                    dropZoneOverlayView.animator().alphaValue = 1
                }
            }
        } else {
            guard !dropZoneOverlayView.isHidden else { return }
            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
#if DEBUG
            logDropZoneOverlay(event: "hide", zone: nil, frame: nil)
#endif

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.activeDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
#if DEBUG
                self.logDropZoneOverlay(event: "hideComplete", zone: nil, frame: nil)
#endif
            }
        }
    }

    func setPaneDropContext(_ context: TerminalPaneDropContext?) {
        paneDropTargetView.dropContext = context
        if context == nil {
            paneDropTargetView.draggingExited(nil)
        }
    }

    func paneDropTargetForDrop(at localPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard bounds.contains(localPoint) else { return nil }
        let pointInTarget = paneDropTargetView.convert(localPoint, from: self)
        guard paneDropTargetView.bounds.contains(pointInTarget) else { return nil }
        guard !paneDropTargetView.shouldDeferToPaneTabBar(at: pointInTarget) else { return nil }
        return paneDropTargetView
    }

#if DEBUG
    private func logDropZoneOverlay(event: String, zone: DropZone?, frame: CGRect?) {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let zoneText = zone.map { String(describing: $0) } ?? "none"
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let scrollOriginText = String(
            format: "%.1f,%.1f",
            scrollView.contentView.bounds.origin.x,
            scrollView.contentView.bounds.origin.y
        )
        let surfaceOriginText = String(
            format: "%.1f,%.1f",
            surfaceView.frame.origin.x,
            surfaceView.frame.origin.y
        )
        let frameText: String
        if let frame {
            frameText = String(
                format: "%.1f,%.1f %.1fx%.1f",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
        } else {
            frameText = "-"
        }
        let signature =
            "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(overlaySuperviewClass)|" +
            "\(scrollOriginText)|\(surfaceOriginText)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDropZoneOverlayLogSignature != signature else { return }
        lastDropZoneOverlayLogSignature = signature
        cmuxDebugLog(
            "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
            "hidden=\(dropZoneOverlayView.isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(scrollOriginText) surfaceOrigin=\(surfaceOriginText)"
        )
    }
#endif

    func triggerFlash(style: FlashStyle = .navigation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastFlashStyle = style
            #if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath(style: style)
            self.updateFlashAppearance(style: style)
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = FocusFlashPattern.values.map { NSNumber(value: $0) }
            animation.keyTimes = FocusFlashPattern.keyTimes.map { NSNumber(value: $0) }
            animation.duration = FocusFlashPattern.duration
            animation.timingFunctions = FocusFlashPattern.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        let wasVisible = surfaceView.isVisibleInUI
        surfaceView.setVisibleInUI(visible)
        isHidden = !visible
        if wasVisible != visible, lastRequestedPortalOcclusionVisible != visible {
            lastRequestedPortalOcclusionVisible = visible
            surfaceView.terminalSurface?.setOcclusion(visible)
        }
#if DEBUG
        if wasVisible != visible {
            let transition = "\(wasVisible ? 1 : 0)->\(visible ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.visible",
                suffix: suffix
            )
        }
#endif
        if wasVisible != visible {
            NotificationCenter.default.post(
                name: .terminalPortalVisibilityDidChange,
                object: self,
                userInfo: [
                    GhosttyNotificationKey.surfaceId: surfaceView.terminalSurface?.id as Any,
                    GhosttyNotificationKey.tabId: surfaceView.tabId as Any
                ]
            )
        }
        if !visible {
            // If we were focused, yield first responder.
            if let window = uiWindow, let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                window.makeFirstResponder(nil)
            }
        } else if !wasVisible {
            // Workspace/sidebar selection can make an already-sized terminal visible again
            // without a portal frame delta or a focus handoff. Reuse the portal refresh
            // path so the Metal layer is nudged immediately on plain visibility restores.
            refreshSurfaceNow(reason: "setVisibleInUI")
            scheduleAutomaticFirstResponderApply(reason: "setVisibleInUI")
        }
    }

    var debugPortalVisibleInUI: Bool {
        surfaceView.isVisibleInUI
    }

    var debugPortalActive: Bool {
        isActive
    }

    var debugPortalFrameInWindow: CGRect {
        guard uiWindow != nil else { return .zero }
        return convert(bounds, to: nil)
    }

    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
#if DEBUG
        if wasActive != active {
            let transition = "\(wasActive ? 1 : 0)->\(active ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.active",
                suffix: suffix
            )
        }
#endif
        if active && !wasActive {
            scheduleAutomaticFirstResponderApply(reason: "setActive")
        } else if !active {
            resignOwnedFirstResponderIfNeeded(reason: "setActive(false)")
        }
    }

#if DEBUG
    private func debugLogWorkspaceSwitchTiming(event: String, suffix: String) {
        guard let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() else {
            cmuxDebugLog("\(event) id=none \(suffix)")
            return
        }
        let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
        cmuxDebugLog("\(event) id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) \(suffix)")
    }

    private func debugFirstResponderLabel() -> String {
        guard let window = uiWindow, let firstResponder = window.firstResponder else { return "nil" }
        if let view = firstResponder as? NSView {
            if view === surfaceView {
                return "surfaceView"
            }
            if view.isDescendant(of: surfaceView) {
                return "surfaceDescendant"
            }
            return String(describing: type(of: view))
        }
        return String(describing: type(of: firstResponder))
    }

    private func debugVisibilityStateSuffix(transition: String) -> String {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let hiddenInHierarchy = (isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor) ? 1 : 0
        let inWindow = uiWindow != nil ? 1 : 0
        let hasSuperview = superview != nil ? 1 : 0
        let hostHidden = isHidden ? 1 : 0
        let surfaceHidden = surfaceView.isHidden ? 1 : 0
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let frameText = String(format: "%.1fx%.1f", frame.width, frame.height)
        let responder = debugFirstResponderLabel()
        return
            "surface=\(surface) transition=\(transition) active=\(isActive ? 1 : 0) " +
            "visibleFlag=\(surfaceView.isVisibleInUI ? 1 : 0) hostHidden=\(hostHidden) surfaceHidden=\(surfaceHidden) " +
            "hiddenHierarchy=\(hiddenInHierarchy) inWindow=\(inWindow) hasSuperview=\(hasSuperview) " +
            "bounds=\(boundsText) frame=\(frameText) firstResponder=\(responder)"
    }
#endif

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
#if DEBUG
        let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let searchActive = self.surfaceView.terminalSurface?.searchState != nil
        cmuxDebugLog(
            "find.moveFocus to=\(surfaceShort) " +
            "from=\(previous?.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "searchState=\(searchActive ? "active" : "nil") " +
            "delayMs=\(Int((delay ?? 0) * 1000))"
        )
#endif
        let work = { [weak self] in
            guard let self else { return }
            guard let window = self.uiWindow else { return }
#if DEBUG
            let before = String(describing: window.firstResponder)
#endif
            guard self.canRequestSurfaceFirstResponder(in: window, reason: "moveFocus") else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            let result = window.makeFirstResponder(self.surfaceView)
#if DEBUG
            cmuxDebugLog(
                "find.moveFocus.apply to=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) before=\(before) after=\(String(describing: window.firstResponder))"
            )
#endif
        }

        if let delay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        } else {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async { work() }
            }
        }
    }

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String], asImageData: Bool = false) -> Bool {
        surfaceView.debugSimulateFileDrop(paths: paths, asImageData: asImageData)
    }

    func debugPendingSurfaceSize() -> CGSize? {
        surfaceView.debugPendingSurfaceSize()
    }

    func debugRegisteredDropTypes() -> [String] {
        surfaceView.debugRegisteredDropTypes()
    }

    func debugInactiveOverlayState() -> (isHidden: Bool, alpha: CGFloat) {
        (
            inactiveOverlayView.isHidden,
            inactiveOverlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
        )
    }

    func debugNotificationRingState() -> (isHidden: Bool, opacity: Float) {
        (
            notificationRingOverlayView.isHidden,
            notificationRingLayer.opacity
        )
    }

    struct DebugDropZoneOverlayState {
        let isHidden: Bool
        let frame: CGRect
        let isAttachedToHostedView: Bool
        let isAttachedToParentContainer: Bool
    }

    func debugDropZoneOverlayState() -> DebugDropZoneOverlayState {
        DebugDropZoneOverlayState(
            isHidden: dropZoneOverlayView.isHidden,
            frame: dropZoneOverlayView.frame,
            isAttachedToHostedView: dropZoneOverlayView.superview === self,
            isAttachedToParentContainer: dropZoneOverlayView.superview === superview
        )
    }

    func debugHasSearchOverlay() -> Bool {
        guard let overlay = searchOverlayHostingView else { return false }
        return overlay.superview === self && !overlay.isHidden
    }

    func debugSearchOverlayHostingViewForTesting() -> NSView? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return overlay
    }

    func debugSurfaceHasPendingLeftMouseReleaseForTesting() -> Bool {
        surfaceView.debugHasPendingLeftMouseReleaseForTesting()
    }

    func debugHasKeyboardCopyModeIndicator() -> Bool {
        keyboardCopyModeBadgeContainerView.superview === self && !keyboardCopyModeBadgeContainerView.isHidden
    }

#endif

    fileprivate var hasActiveDropZoneOverlay: Bool {
        activeDropZone != nil || pendingDropZone != nil
    }

    /// Handle file/URL drops, forwarding to the terminal as shell-escaped paths.
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        #if DEBUG
        cmuxDebugLog("terminal.swiftUIDrop surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") urls=\(urls.map(\.lastPathComponent))")
        #endif
        return surfaceView.handleDroppedFileURLs(urls)
    }

    func terminalViewForDrop(at point: NSPoint) -> GhosttyNSView? {
        guard bounds.contains(point), !isHidden else { return nil }
        return surfaceView
    }

#if DEBUG
    /// Sends a synthetic key press/release pair directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike sendText, which bypasses key translation.
    @discardableResult
    func debugSendSyntheticKeyPressAndReleaseForUITest(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let window = uiWindow else { return false }
        window.makeFirstResponder(surfaceView)

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        guard let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        surfaceView.keyDown(with: keyDown)
        surfaceView.keyUp(with: keyUp)
        return true
    }

    /// Sends a synthetic Ctrl+D key press directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike `sendText`, which bypasses key translation.
    @discardableResult
    func sendSyntheticCtrlDForUITest(modifierFlags: NSEvent.ModifierFlags = [.control]) -> Bool {
        debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            keyCode: 2,
            modifierFlags: modifierFlags
        )
    }
    #endif

    func ensureFocus(
        for tabId: UUID,
        surfaceId: UUID,
        respectForeignFirstResponder: Bool = true
    ) {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard let window = uiWindow else { return }
        guard surfaceView.isVisibleInUI else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=not_visible"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.notVisible")
            return
        }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.hiddenOrTiny")
            return
        }

        if let terminalSurface = surfaceView.terminalSurface,
           terminalSurface.focusPlacement == .rightSidebarDock {
            guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
                workspaceId: tabId,
                panelId: surfaceId,
                in: window
            ) != false else {
#if DEBUG
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dockCoordinator")
#endif
                return
            }
            if terminalSurface.searchState != nil {
#if DEBUG
                cmuxDebugLog(
                    "focus.ensure.dock.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "firstResponder=\(String(describing: window.firstResponder))"
                )
#endif
                restoreSearchFocus(window: window)
                return
            }
            if let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.alreadyFirstResponder")
                return
            }
            if respectForeignFirstResponder,
               let firstResponder = window.firstResponder,
               shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
                let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dock.\(reason)")
#endif
                return
            }
            let result = window.makeFirstResponder(surfaceView)
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.dock.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            if isSurfaceViewFirstResponder() {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.afterMakeFirstResponder")
            }
            return
        }

        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.inactiveTab")
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.missingPane")
            return
        }

        guard tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface,
              tab.bonsplitController.focusedPaneId == paneId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.unfocusedPane")
            return
        }

        guard delegate.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: surfaceId, in: window) else {
#if DEBUG
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=coordinatorRightSidebar")
#endif
            return
        }

        // Search focus restoration — only after confirming this is the active tab/pane.
        if surfaceView.terminalSurface?.searchState != nil {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            restoreSearchFocus(window: window)
            return
        }

        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.alreadyFirstResponder")
            return
        }

        // Layout and visibility reconciliation can ask the active terminal to
        // reassert focus after a sidebar/text owner has already accepted focus.
        // Respect those explicit AppKit first responders unless the terminal
        // surface already owns focus.
        if respectForeignFirstResponder,
           let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=\(reason)")
#endif
            return
        }

        if !window.isKeyWindow {
            guard shouldAllowEnsureFocusWindowActivation(
                activeTabManager: delegate.tabManager,
                targetTabManager: tabManager,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                targetWindow: window
            ) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
        }
        let result = window.makeFirstResponder(surfaceView)
#if DEBUG
        cmuxDebugLog(
            "focus.ensure.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
            "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        if !isSurfaceViewFirstResponder() {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.afterMakeFirstResponder")
        } else {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.afterMakeFirstResponder")
        }
    }

    func yieldTerminalSurfaceFocusForForeignResponder(reason: String) {
        surfaceView.desiredFocus = false
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        terminalSurface.setFocus(false)
#if DEBUG
        dlog("focus.surface.yield surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func matchesCurrentTerminalFocusTarget(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            return false
        }

        return tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface &&
            tab.bonsplitController.focusedPaneId == paneId
    }

    /// Suppress the surface view's onFocus callback and ghostty_surface_set_focus during
    /// SwiftUI reparenting (programmatic splits). Call clearSuppressReparentFocus() after layout settles.
    func suppressReparentFocus() {
        surfaceView.suppressingReparentFocus = true
    }

    func isSuppressingReparentFocusForLayoutFollowUp() -> Bool {
        surfaceView.suppressingReparentFocus
    }

    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool {
        // After Workspace has flushed a layout follow-up, the protected reparent
        // turn has passed even if AppKit never tried to focus this old view.
        true
    }

    func clearReparentFocusSuppressionForPointerFocus() {
        guard surfaceView.suppressingReparentFocus else { return }
        surfaceView.suppressingReparentFocus = false
#if DEBUG
        cmuxDebugLog("focus.reparent.pointerClear surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
    }

    func clearSuppressReparentFocus() {
        surfaceView.suppressingReparentFocus = false
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let surfaceOwnsFirstResponder = currentTerminalSurfaceOwnsFirstResponder()

        guard surfaceView.desiredFocus || surfaceOwnsFirstResponder else { return }
        guard surfaceView.isVisibleInUI else { return }
        surfaceView.terminalSurface?.recordExternalFocusState(true)
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.defer surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "clearSuppressReparentFocus.hiddenOrTiny")
            return
        }
        if !surfaceOwnsFirstResponder && !isSurfaceViewFirstResponder() {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.restoreFirstResponder surface=\(surfaceShort) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            guard requestSurfaceFirstResponder(in: window, reason: "clearSuppressReparentFocus"),
                  isSurfaceViewFirstResponder() else { return }
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.resume surface=\(surfaceShort) firstResponder=\(String(describing: window.firstResponder))")
#endif
        reassertTerminalSurfaceFocus(reason: "clearSuppressReparentFocus", force: true)
    }

    /// Returns true if the terminal's actual Ghostty surface view is (or contains) the window first responder.
    /// This is stricter than checking `hostedView` descendants, since the scroll view can sometimes become
    /// first responder transiently while focus is being applied.
    func isSurfaceViewFirstResponder() -> Bool {
        guard let window = uiWindow, let fr = window.firstResponder as? NSView else { return false }
        return fr === surfaceView || fr.isDescendant(of: surfaceView)
    }

#if DEBUG
    func debugIsSuppressingReparentFocusForTesting() -> Bool {
        surfaceView.suppressingReparentFocus
    }
#endif

    private func currentTerminalSurfaceOwnsFirstResponder() -> Bool {
        guard let window = uiWindow, let firstResponder = window.firstResponder as? NSView else { return false }
        if firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView) {
            return true
        }
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        var current: NSView? = firstResponder
        while let view = current {
            if let ghosttyView = view as? GhosttyNSView,
               ghosttyView.terminalSurface === terminalSurface {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func canRequestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return true
        }
        let allowed = AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id,
            in: window
        ) ?? true
#if DEBUG
        if !allowed {
            dlog(
                "focus.apply.skip surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "reason=\(reason).coordinatorRightSidebar"
            )
        }
#endif
        return allowed
    }

    @discardableResult
    private func requestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard canRequestSurfaceFirstResponder(in: window, reason: reason) else {
            return false
        }
        return window.makeFirstResponder(surfaceView)
    }

    private func scheduleAutomaticFirstResponderApply(reason: String) {
        guard !pendingAutomaticFirstResponderApply else { return }
        pendingAutomaticFirstResponderApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutomaticFirstResponderApply = false
#if DEBUG
            let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog("find.applyFirstResponder.defer surface=\(surfaceShort) reason=\(reason)")
#endif
            self.applyFirstResponderIfNeeded()
        }
    }

    private func reassertTerminalSurfaceFocus(reason: String, force: Bool = false) {
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        if terminalSurface.surface == nil {
            terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        }
#if DEBUG
        cmuxDebugLog("focus.surface.reassert surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.setFocus(true, force: force)
        refreshSurfaceAfterFocusIfNeeded(reason: reason)
    }

    private func refreshSurfaceAfterFocusIfNeeded(reason: String) {
        guard let terminalSurface = surfaceView.terminalSurface,
              isActive,
              let window = uiWindow,
              window.isKeyWindow,
              surfaceView.isVisibleInUI else { return }

        let now = CACurrentMediaTime()
        if now - lastFocusRefreshAt < 0.05 {
            return
        }
        lastFocusRefreshAt = now
#if DEBUG
        cmuxDebugLog("focus.surface.refresh surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func applyFirstResponderIfNeeded() {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")

        guard isActive else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.apply.skip surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return
        }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard let tabId = surfaceView.tabId,
              let panelId = surfaceView.terminalSurface?.id,
              matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: panelId) else {
#if DEBUG
            cmuxDebugLog("focus.apply.skip surface=\(surfaceShort) reason=stale_target")
#endif
            return
        }
        if AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: panelId, in: window) == false {
#if DEBUG
            dlog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=coordinatorRightSidebar")
#endif
            return
        }
        if AppDelegate.shared?.isCommandPaletteEffectivelyVisible(for: window) == true {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=commandPaletteVisible")
#endif
            return
        }
        if surfaceView.terminalSurface?.searchState != nil {
            // Find bar is open. Restore focus based on what the user last intended.
            restoreSearchFocus(window: window)
            return
        }
        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.alreadyFirstResponder")
            return
        }
        // Don't steal focus from a search overlay on another surface in this window.
        if let fr = window.firstResponder, isSearchOverlayOrDescendant(fr) {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=searchOverlayFocused")
#endif
            return
        }
        // Don't steal focus from active non-terminal input owners. The terminal surface uses its
        // own GhosttyNSView for input, so NSText and the feed focus host are always foreign focus
        // owners that should survive deferred terminal visibility applies.
        if let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=\(reason)")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("find.applyFirstResponder APPLY surface=\(surfaceShort) prevFirstResponder=\(String(describing: window.firstResponder))")
#endif
        window.makeFirstResponder(surfaceView)
        if isSurfaceViewFirstResponder() {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.afterMakeFirstResponder")
        }
    }

    /// Restore focus when window becomes key and the find bar is open.
    /// Respects `searchFocusTarget` so Escape-to-terminal intent is preserved across window switches.
    private func restoreSearchFocus(window: NSWindow) {
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        switch searchFocusTarget {
        case .searchField:
            if let firstResponder = window.firstResponder,
               isCurrentSurfaceSearchFieldResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=alreadyFocused firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if let firstResponder = window.firstResponder,
               isSearchOverlayOrDescendant(firstResponder),
               !isCurrentSurfaceSearchResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=foreignSearchResponder firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if focusMountedSearchFieldIfAvailable(window: window, surfaceShort: surfaceShort) {
                return
            }
            // Explicitly unfocus the terminal so cursor stops blinking immediately.
            // The notification observer also does this, but it runs async when posted from main.
            surfaceView.terminalSurface?.setFocus(false)
            // Post notification — SearchTextFieldRepresentable's Coordinator
            // observes it and calls makeFirstResponder on the native NSTextField.
            if let terminalSurface = surfaceView.terminalSurface {
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
                "via=notification firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        case .terminal:
            let result = requestSurfaceFirstResponder(in: window, reason: "restoreSearchFocus.terminal")
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=terminal " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        }
    }

    @discardableResult
    private func focusMountedSearchFieldIfAvailable(
        window: NSWindow,
        surfaceShort: String
    ) -> Bool {
        guard canApplyMountedSearchFieldFocusRequest() else {
            return false
        }
        guard let field = mountedSearchFieldIfAvailable() else {
            return false
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)

        surfaceView.terminalSurface?.setFocus(false)

#if DEBUG
        if alreadyFocused {
            cmuxDebugLog(
                "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                "reason=mountedFieldAlreadyFocused firstResponder=\(String(describing: firstResponder))"
            )
        }
#endif
        guard !alreadyFocused else { return true }

        let result = window.makeFirstResponder(field)
        let ownsField = mountedSearchFieldOwnsResponder(window.firstResponder, field: field)

#if DEBUG
        cmuxDebugLog(
            "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
            "via=mountedField result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        return ownsField
    }

    func capturePanelFocusIntent(in window: NSWindow?) -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil {
            if let firstResponder = window?.firstResponder as? NSView,
               (firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView)) {
                return .surface
            }
            if let firstResponder = window?.firstResponder,
               isCurrentSurfaceSearchResponder(firstResponder) {
                return .findField
            }
            if searchFocusTarget == .searchField {
                return .findField
            }
        }
        return .surface
    }

    func preferredPanelFocusIntentForActivation() -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil, searchFocusTarget == .searchField {
            return .findField
        }
        return .surface
    }

    func responderMatchesPreferredKeyboardFocus(_ responder: NSResponder) -> Bool {
        switch preferredPanelFocusIntentForActivation() {
        case .surface:
            guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)

        case .findField:
            return isCurrentSurfaceSearchResponder(responder) &&
                isSearchOverlayOrDescendant(responder)
        case .textBoxInput:
            return false
        }
    }

    func preparePanelFocusIntentForActivation(_ intent: TerminalPanelFocusIntent) {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
        case .findField:
            guard surfaceView.terminalSurface?.searchState != nil else { return }
            searchFocusTarget = .searchField
        case .textBoxInput:
            searchFocusTarget = .terminal
        }
#if DEBUG
        let targetLabel: String = {
            switch intent {
            case .surface:
                return "terminal"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        cmuxDebugLog(
            "find.preparePanelFocusIntent surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(targetLabel)"
        )
#endif
    }

    @discardableResult
    func restorePanelFocusIntent(_ intent: TerminalPanelFocusIntent) -> Bool {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
            setActive(true)
            applyFirstResponderIfNeeded()
            return true
        case .findField:
            guard let terminalSurface = surfaceView.terminalSurface,
                  terminalSurface.searchState != nil else {
                return false
            }
            searchFocusTarget = .searchField
            setActive(true)
            if let window {
                restoreSearchFocus(window: window)
            } else {
                terminalSurface.setFocus(false)
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restorePanelFocusIntent surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "target=searchField firstResponder=\(String(describing: window?.firstResponder))"
            )
#endif
            return true
        case .textBoxInput:
            return false
        }
    }

    func ownedPanelFocusIntent(for responder: NSResponder) -> TerminalPanelFocusIntent? {
        if isCurrentSurfaceSearchResponder(responder) {
            return .findField
        }

        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return nil }
        if view === surfaceView || view.isDescendant(of: surfaceView) {
            return .surface
        }
        return nil
    }

    @discardableResult
    func yieldPanelFocusIntent(_ intent: TerminalPanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent != .textBoxInput else {
            return false
        }
        guard let firstResponder = window.firstResponder,
              ownedPanelFocusIntent(for: firstResponder) == intent else {
            return false
        }
        if intent == .findField { _ = cmuxRememberFindSelection(in: searchOverlayHostingView) }
        surfaceView.terminalSurface?.setFocus(false)
        resignOwnedFirstResponderIfNeeded(reason: "yieldPanelFocusIntent")
#if DEBUG
        cmuxDebugLog(
            "focus.handoff.yield surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(intent == .findField ? "searchField" : "terminal")"
        )
#endif
        return true
    }

    private func resignOwnedFirstResponderIfNeeded(reason: String) {
        guard let window,
              let firstResponder = window.firstResponder else { return }

        let ownsSurfaceResponder: Bool = {
            guard let view = firstResponder as? NSView else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)
        }()

        guard ownsSurfaceResponder || isCurrentSurfaceSearchResponder(firstResponder) else { return }

#if DEBUG
        cmuxDebugLog(
            "focus.surface.resign surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) firstResponder=\(String(describing: firstResponder))"
        )
#endif
        window.makeFirstResponder(nil)
    }

    /// Check if a responder is inside a search overlay hosting view.
    /// Handles the AppKit field-editor case: when an NSTextField is being edited,
    /// window.firstResponder is the shared NSTextView field editor, not the text field.
    private func isSearchOverlayOrDescendant(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        var current: NSView? = view
        while let v = current {
            if v is NSHostingView<SurfaceSearchOverlay> { return true }
            let typeName = String(describing: type(of: v))
            if typeName.contains("BrowserSearchOverlay") { return true }
            current = v.superview
        }
        return false
    }

    private func isCurrentSurfaceSearchResponder(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        return view.isDescendant(of: self)
    }

    private func isCurrentSurfaceSearchFieldResponder(_ responder: NSResponder) -> Bool {
        if let mountedSearchField = mountedSearchFieldIfAvailable(),
           mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField.isDescendant(of: self) &&
                isSearchOverlayOrDescendant(mountedSearchField)
        }

        guard let textField = responder as? NSTextField else { return false }
        return textField.isDescendant(of: self) && isSearchOverlayOrDescendant(textField)
    }

#if DEBUG
    struct DebugRenderStats {
        let drawCount: Int
        let lastDrawTime: CFTimeInterval
        let metalDrawableCount: Int
        let metalLastDrawableTime: CFTimeInterval
        let presentCount: Int
        let lastPresentTime: CFTimeInterval
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func debugRenderStats() -> DebugRenderStats {
        let layerClass = surfaceView.layer.map { String(describing: type(of: $0)) } ?? "nil"
        let (metalCount, metalLast) = (surfaceView.layer as? GhosttyMetalLayer)?.debugStats() ?? (0, 0)
        let (drawCount, lastDraw): (Int, CFTimeInterval) = surfaceView.terminalSurface.map { terminalSurface in
            Self.drawStats(for: terminalSurface.id)
        } ?? (0, 0)
        let (presentCount, lastPresent, contentsKey): (Int, CFTimeInterval, String) = surfaceView.terminalSurface.map { terminalSurface in
            let stats = Self.updatePresentStats(surfaceId: terminalSurface.id, layer: surfaceView.layer)
            return (stats.count, stats.last, stats.key)
        } ?? (0, 0, Self.contentsKey(for: surfaceView.layer))
        let inWindow = (window != nil)
        let windowIsKey = window?.isKeyWindow ?? false
        let windowOcclusionVisible = (window?.occlusionState.contains(.visible) ?? false) || (window?.isKeyWindow ?? false)
        let appIsActive = NSApp.isActive
        let fr = window?.firstResponder as? NSView
        let isFirstResponder = fr == surfaceView || (fr?.isDescendant(of: surfaceView) ?? false)
        return DebugRenderStats(
            drawCount: drawCount,
            lastDrawTime: lastDraw,
            metalDrawableCount: metalCount,
            metalLastDrawableTime: metalLast,
            presentCount: presentCount,
            lastPresentTime: lastPresent,
            layerClass: layerClass,
            layerContentsKey: contentsKey,
            inWindow: inWindow,
            windowIsKey: windowIsKey,
            windowOcclusionVisible: windowOcclusionVisible,
            appIsActive: appIsActive,
            isActive: isActive,
            desiredFocus: surfaceView.desiredFocus,
            isFirstResponder: isFirstResponder
        )
    }
#endif

#if DEBUG
    struct DebugFrameSample {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64
        let iosurfaceWidthPx: Int
        let iosurfaceHeightPx: Int
        let expectedWidthPx: Int
        let expectedHeightPx: Int
        let layerClass: String
        let layerContentsGravity: String
        let layerContentsKey: String

        var isProbablyBlank: Bool {
            (lumaStdDev < 3.5 && modeFraction > 0.985) ||
            (uniqueQuantized <= 6 && modeFraction > 0.95)
        }
    }

    /// Create a CGImage from the terminal's IOSurface-backed layer contents.
    ///
    /// This avoids Screen Recording permissions (unlike CGWindowListCreateImage) and is therefore
    /// suitable for debug socket tests running in headless/VM contexts.
    func debugCopyIOSurfaceCGImage() -> CGImage? {
        guard let modelLayer = surfaceView.layer else { return nil }
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return nil }

        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        let surfaceRef = (contents as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        let bytesPerRow = Int(IOSurfaceGetBytesPerRow(surfaceRef))
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let size = bytesPerRow * height
        let data = Data(bytes: base, count: size)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Sample the IOSurface backing the terminal layer (if any) to detect a transient blank frame
    /// without using screenshots/screen recording permissions.
    func debugSampleIOSurface(normalizedCrop: CGRect) -> DebugFrameSample? {
        guard let modelLayer = surfaceView.layer else { return nil }
        // Prefer the presentation layer to better match what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        let layerClass = String(describing: type(of: layer))
        let layerContentsGravity = layer.contentsGravity.rawValue
        let contentsKey = Self.contentsKey(for: layer)
        let presentationScale = max(1.0, layer.contentsScale)
        let expectedWidthPx = Int((layer.bounds.width * presentationScale).rounded(.toNearestOrAwayFromZero))
        let expectedHeightPx = Int((layer.bounds.height * presentationScale).rounded(.toNearestOrAwayFromZero))

        // Ghostty uses a CoreAnimation layer whose `contents` is an IOSurface-backed object.
        // The concrete layer class is often `IOSurfaceLayer` (private), so avoid referencing it directly.
        guard let anySurface = layer.contents else {
            // Treat "no contents" as a blank frame: this is the visual regression we're guarding.
            return DebugFrameSample(
                sampleCount: 0,
                uniqueQuantized: 0,
                lumaStdDev: 0,
                modeFraction: 1,
                fingerprint: 0,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        // IOSurfaceLayer.contents is usually an IOSurface, but during mitigation we may
        // temporarily replace contents with a CGImage snapshot to avoid blank flashes.
        // Treat non-IOSurface contents as "non-blank" and avoid unsafe casts.
        let cf = anySurface as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else {
            var fnv: UInt64 = 1469598103934665603
            for b in contentsKey.utf8 {
                fnv ^= UInt64(b)
                fnv &*= 1099511628211
            }
            return DebugFrameSample(
                sampleCount: 1,
                uniqueQuantized: 1,
                lumaStdDev: 999,
                modeFraction: 0,
                fingerprint: fnv,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        let surfaceRef = (anySurface as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surfaceRef)
        if bytesPerRow <= 0 { return nil }

        // Assume 4 bytes/pixel BGRA (common for IOSurfaceLayer contents).
        let bytesPerPixel = 4
        let step = 6

        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        var count = 0
        var fnv: UInt64 = 1469598103934665603

        for y in stride(from: y0, to: y1, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: x0, to: x1, by: step) {
                let p = row.advanced(by: x * bytesPerPixel)
                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(r) >> 4)
                let gq = UInt16(UInt8(g) >> 4)
                let bq = UInt16(UInt8(b) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                let lq = UInt8(max(0, min(63, Int(luma / 4.0))))
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return DebugFrameSample(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv,
            iosurfaceWidthPx: width,
            iosurfaceHeightPx: height,
            expectedWidthPx: expectedWidthPx,
            expectedHeightPx: expectedHeightPx,
            layerClass: layerClass,
            layerContentsGravity: layerContentsGravity,
            layerContentsKey: contentsKey
        )
    }
#endif

    func cancelFocusRequest() {
        // Intentionally no-op (no retry loops).
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        guard !pointApproximatelyEqual(surfaceView.frame.origin, visibleRect.origin) else { return }
#if DEBUG
        logDragGeometryChange(event: "surfaceOrigin", old: surfaceView.frame.origin, new: visibleRect.origin)
#endif
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Match upstream Ghostty behavior: use content area width (excluding non-content
    /// regions such as scrollbar space) when telling libghostty the terminal size.
    @discardableResult
    private func synchronizeCoreSurface() -> Bool {
        let width = max(0, surfaceView.frame.width)
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return false }
        return surfaceView.pushTargetSurfaceSize(CGSize(width: width, height: height))
    }

    private func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: NotificationRingMetrics.inset,
            radius: NotificationRingMetrics.cornerRadius
        )
    }

    private func updateFlashPath(style: FlashStyle) {
        let inset: CGFloat
        let radius: CGFloat
        switch style {
        case .navigation, .notification:
            inset = NotificationRingMetrics.inset
            radius = NotificationRingMetrics.cornerRadius
        }
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: inset,
            radius: radius
        )
    }

    private func updateFlashAppearance(style: FlashStyle) {
        let presentation = Self.flashPresentation(for: style)
        let strokeColor = presentation.accent.strokeColor
        flashLayer.strokeColor = strokeColor.cgColor
        flashLayer.shadowColor = strokeColor.cgColor
        flashLayer.shadowOpacity = Float(presentation.glowOpacity)
        flashLayer.shadowRadius = presentation.glowRadius
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = PanelOverlayRingMetrics.pathRect(in: bounds)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        var didChangeGeometry = false
        let targetDocumentHeight = documentHeight()
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                // Check if we're currently at the bottom (with threshold for float drift)
                let currentOrigin = scrollView.contentView.bounds.origin
                let documentHeight = documentView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let distanceFromBottom = documentHeight - currentOrigin.y - viewportHeight
                let isAtBottom = distanceFromBottom <= Self.scrollToBottomThreshold

                // Update userScrolledAwayFromBottom based on current position
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                // Passive bottom packets should not override an explicit scrollback review,
                // but the first scrollbar packet caused by the user's own wheel input should
                // still move the viewport to the requested scrollback position.
                let shouldAutoScroll = !userScrolledAwayFromBottom || allowExplicitScrollbarSync

                if shouldAutoScroll && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                }
                lastSentRow = Int(scrollbar.offset)
            }
        }

        allowExplicitScrollbarSync = false

        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height

        // Track if user has scrolled away from bottom to review scrollback
        if scrollOffset > Self.scrollToBottomThreshold {
            userScrolledAwayFromBottom = true
        } else if scrollOffset <= 0 {
            userScrolledAwayFromBottom = false
        }

        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        let wasVisible = scrollView.hasVerticalScroller
        if pendingExplicitWheelScroll {
            userScrolledAwayFromBottom = scrollbar.offset + scrollbar.len < scrollbar.total
            allowExplicitScrollbarSync = true
            pendingExplicitWheelScroll = false
        }
        surfaceView.scrollbar = scrollbar
        let isVisible = shouldShowTerminalScrollBar()
        if wasVisible != isVisible {
            _ = synchronizeGeometryAndContent()
            return
        }
        synchronizeScrollView()
    }

    @discardableResult
    private func synchronizeScrollbarAppearance() -> Bool {
        let shouldShowScrollBar = shouldShowTerminalScrollBar()
        let didChange =
            scrollView.hasVerticalScroller != shouldShowScrollBar ||
            scrollView.autohidesScrollers != false ||
            scrollView.scrollerStyle != .overlay
        scrollView.hasVerticalScroller = shouldShowScrollBar
        // Mirror upstream Ghostty: keep overlay scrollers even when the
        // system preference is legacy so terminal content never sits beneath a
        // permanently reserved scrollbar gutter.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        updateTrackingAreas()
        return didChange
    }

    private func handlePreferredScrollerStyleChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePreferredScrollerStyleChange()
            }
            return
        }

        synchronizeScrollbarAppearance()

        // Retile just the scroll view so contentSize reflects the current
        // scroller preference without perturbing hosted terminal geometry.
        scrollView.tile()
        _ = synchronizeCoreSurface()
    }

    private func handleTerminalScrollBarPreferenceChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleTerminalScrollBarPreferenceChange()
            }
            return
        }

        _ = synchronizeGeometryAndContent()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    private func terminalScrollBarAllowedBySettings() -> Bool {
        guard GhosttyApp.shared.scrollbarVisibility() != .never else { return false }
        guard TerminalScrollBarSettings.isVisible() else { return false }
        return true
    }

    private func surfaceHasScrollback() -> Bool? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        // Embedded Ghostty exposes alternate-screen TUIs to the wrapper as a
        // viewport with no additional scrollback (`total <= len`). Treat that
        // as the signal to suppress the overlay scrollbar so full-screen apps
        // like nvim/htop do not pin it on top of the rightmost cell column.
        return scrollbar.total > scrollbar.len
    }

    private func shouldShowTerminalScrollBar() -> Bool {
        guard terminalScrollBarAllowedBySettings() else { return false }
        guard let hasScrollback = surfaceHasScrollback() else {
            // Ghostty reports scrollback asynchronously. Until the first packet
            // arrives, keep the scroller visible so restored/reattached
            // surfaces with existing scrollback do not appear broken.
            return true
        }
        return hasScrollback
    }

}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    /// Deliver committed text using typed-input semantics so shells and editors
    /// keep their normal interactive behaviors (autosuggestions, Return
    /// execution, etc.). Programmatic callers can preserve literal ESC bytes so
    /// automation payloads remain byte-for-byte stable.
    fileprivate func sendTextToSurface(_ chars: String, preserveLiteralEscape: Bool) {
        guard let surface = surface else { return }
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
#endif
#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeInsertTextCharsHex": cmuxScalarHex(chars),
                "probeInsertTextSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeInsertTextCount": 1]
        )
#endif

        var bufferedText = ""
        var previousWasCR = false

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            bufferedText.withCString { ptr in
                keyEvent.text = ptr
                _ = sendGhosttyKey(surface, keyEvent)
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func sendControlKey(_ keycode: UInt32) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = keycode
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            keyEvent.text = nil
            _ = sendGhosttyKey(surface, keyEvent)
        }

        for scalar in chars.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    sendControlKey(0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushBufferedText()
                sendControlKey(0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushBufferedText()
                sendControlKey(0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                if preserveLiteralEscape {
                    bufferedText.unicodeScalars.append(scalar)
                } else {
                    flushBufferedText()
                    sendControlKey(0x35) // kVK_Escape
                }
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushBufferedText()
#if DEBUG
        CmuxTypingTiming.logDuration(
            path: "terminal.sendTextToSurface",
            startedAt: typingTimingStart,
            extra: "textBytes=\(chars.utf8.count)"
        )
#endif
    }

    /// External accessibility/dictation tools should commit plain text, but
    /// some inject a leading escape sequence first. Strip those bytes on the
    /// committed-text path so they can't leak into the PTY as literals.
    static func sanitizeExternalCommittedText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
                continue
            }

            if byte == 0xC2 {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x9B {
                    // U+009B (C1 CSI) is encoded as the UTF-8 byte pair C2 9B.
                    index = consumeLeadingCSISequence(in: bytes, from: next + 1)
                    continue
                }
            }

            break
        }

        if index == 0 {
            return text
        }

        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private static func consumeLeadingEscapeSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private static func consumeLeadingCSISequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }

            if (0x40...0x7E).contains(byte) {
                return index + 1
            }

            break
        }

        return index
    }

    private static func consumeLeadingEscapedStringSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }

            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }

            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }

            index += 1
        }

        return bytes.count
    }

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        if markedText.length > 0 {
#if DEBUG
            assert(markedSelectedRange.location != NSNotFound, "markedSelectedRange must be valid")
#endif
            return markedSelectedRange
        }
        return readSelectionSnapshot()?.range ?? NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.setMarkedText",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length)"
            )
        }
#endif
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            return
        }
        markedSelectedRange = normalizedMarkedSelectionRange(selectedRange, markedLength: markedText.length)

        // If we're not in a keyDown event, sync preedit immediately.
        // This can happen due to external events like changing keyboard layouts
        // while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    func unmarkText() {
#if DEBUG
        let hadMarkedText = markedText.length > 0
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.unmarkText",
                startedAt: typingTimingStart,
                extra: "hadMarkedText=\(hadMarkedText ? 1 : 0)"
            )
        }
#endif
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty.
    /// This tells Ghostty about IME composition text so it can render the
    /// preedit overlay (e.g. for Korean, Japanese, Chinese input).
    private func syncPreedit(clearIfNeeded: Bool = true) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.syncPreedit",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length) clearIfNeeded=\(clearIfNeeded ? 1 : 0)"
            )
        }
#endif
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedText.length > 0 {
            guard let substringRange = clampedMarkedTextRange(range, markedLength: markedText.length) else { return nil }
            actualRange?.pointee = substringRange
            return markedText.attributedSubstring(from: substringRange)
        }

        guard range.length > 0,
              let snapshot = readSelectionSnapshot() else { return nil }
        actualRange?.pointee = snapshot.range
        return NSAttributedString(string: snapshot.string)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return selectedRange().location
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Use Ghostty's IME point API for accurate cursor position if available.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
#if DEBUG
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let override = imePointOverrideForTesting {
            x = override.x
            y = override.y
            w = override.width
            h = override.height
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#else
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#endif

        if range.length == 0, w > 0 {
            // Dictation expects a caret rect for insertion points rather than a box.
            w = 0
        }

        // Ghostty coordinates are top-left origin; AppKit expects bottom-left.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func attributedString() -> NSAttributedString {
        if markedText.length > 0 {
            return NSAttributedString(attributedString: markedText)
        }
        if let snapshot = readSelectionSnapshot(), !snapshot.string.isEmpty {
            return NSAttributedString(string: snapshot.string)
        }
        return NSAttributedString(string: "")
    }

    func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    @available(macOS 14.0, *)
    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    @available(macOS 14.0, *)
    var documentVisibleRect: NSRect {
        visibleDocumentRectInScreenCoordinates()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.insertText",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "replacementLocation=\(replacementRange.location) replacementLength=\(replacementRange.length)"
            )
        }
#endif
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        if keyTextAccumulator != nil,
           shouldBufferBopomofoInsertedPreedit(chars) {
            insertBopomofoPreeditText(chars, replacementRange: replacementRange)
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // Some IME/input-method paths call insertText with an empty payload to
        // flush state. There is no terminal text to send in that case.
        guard !chars.isEmpty else { return }

        if shouldSuppressDeferredNumpadIMECommit(chars) {
            return
        }

#if DEBUG
        if NSApp.currentEvent == nil {
            cmuxDebugLog("ime.insertText.noEvent len=\(chars.count)")
        }
#endif

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        let isExternalCommittedText = externalCommittedTextDepth > 0
        let sanitizedChars = if isExternalCommittedText {
            // Only sanitize explicit external committed-text paths used by
            // AX/dictation integrations. Programmatic NSTextInputClient callers
            // may intentionally start with ESC/CSI bytes.
            Self.sanitizeExternalCommittedText(chars)
        } else {
            chars
        }

#if DEBUG
        if sanitizedChars != chars {
            cmuxDebugLog(
                "ime.insertText.sanitized originalBytes=\(chars.utf8.count) " +
                "sanitizedBytes=\(sanitizedChars.utf8.count)"
            )
        }
#endif

        guard !sanitizedChars.isEmpty else { return }

        // Otherwise send directly to the terminal
        recordDirectAgentHibernationTerminalInput()
        sendTextToSurface(
            sanitizedChars,
            preserveLiteralEscape: !isExternalCommittedText
        )
    }

    private func insertBopomofoPreeditText(_ chars: String, replacementRange: NSRange) {
        let effectiveRange = effectiveBopomofoPreeditReplacementRange(replacementRange)
        if let range = Range(effectiveRange, in: markedText.string) {
            let insertionLocation = effectiveRange.location + (chars as NSString).length
            let next = markedText.string.replacingCharacters(in: range, with: chars)
            markedText = NSMutableAttributedString(string: next)
            markedSelectedRange = normalizedMarkedSelectionRange(
                NSRange(location: insertionLocation, length: 0),
                markedLength: markedText.length
            )
            return
        }

        markedText.append(NSAttributedString(string: chars))
        markedSelectedRange = normalizedMarkedSelectionRange(
            NSRange(location: markedText.length, length: 0),
            markedLength: markedText.length
        )
    }

    private func effectiveBopomofoPreeditReplacementRange(_ replacementRange: NSRange) -> NSRange {
        guard replacementRange.location == NSNotFound else { return replacementRange }
        guard markedText.length > 0 else { return NSRange(location: 0, length: 0) }
        return normalizedMarkedSelectionRange(markedSelectedRange, markedLength: markedText.length)
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    let paneId: PaneID
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    private final class HostContainerView: NSView {
        private static var nextInstanceSerial: UInt64 = 0

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        let instanceSerial: UInt64
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?

        override init(frame frameRect: NSRect) {
            Self.nextInstanceSerial &+= 1
            instanceSerial = Self.nextInstanceSerial
            super.init(frame: frameRect)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not implemented")
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        private func notifyGeometryChangedIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            notifyGeometryChangedIfNeeded()
        }

        override func layout() {
            super.layout()
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            notifyGeometryChangedIfNeeded()
        }
    }

    final class Coordinator {
        var attachGeneration: Int = 0
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
        weak var hostedView: GhosttySurfaceScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // If this update originates from a stale/replaced host while the hosted view is
        // already attached elsewhere, do not mutate visibility/active state here.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }

    enum HostCallbackPortalGeometrySynchronizationAction<Window> {
        case skip
        case synchronizeWithoutLayoutFlush(Window)
    }

    static func hostCallbackPortalGeometrySynchronizationAction<Window>(
        window: Window?
    ) -> HostCallbackPortalGeometrySynchronizationAction<Window> {
        // HostContainerView callbacks can fire while SwiftUI/AppKit is already
        // rendering or laying out the representable. Keep the immediate path,
        // but forbid ancestor layout flushes from this callback.
        guard let window else { return .skip }
        return .synchronizeWithoutLayoutFlush(window)
    }

    private static func synchronizePortalGeometry(
        for host: HostContainerView,
        coordinator: Coordinator
    ) {
        let geometryRevision = host.geometryRevision
        guard coordinator.lastSynchronizedHostGeometryRevision != geometryRevision else { return }
        coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
        // Avoid forcing ancestor AppKit layout while SwiftUI is still inside
        // the current update/layout turn. Reconcile the portal against the
        // already-current host geometry so terminal content tracks resize
        // without reopening the CATransaction display-link reentry path.
        guard case .synchronizeWithoutLayoutFlush = hostCallbackPortalGeometrySynchronizationAction(
            window: host.window
        ) else { return }
        TerminalWindowPortalRegistry.synchronizeForAnchor(host, syncLayout: false)
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView(frame: .zero)
        container.wantsLayer = false
        // The actual terminal surface lives in the AppKit portal layer above SwiftUI.
        // This empty placeholder should not be walked by the accessibility subsystem.
        container.setAccessibilityRole(.none)
        container.setAccessibilityElement(false)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
        let previousDesiredIsActive = coordinator.desiredIsActive
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        let desiredStateChanged =
            previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if desiredStateChanged {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            }
        }
#endif

        let hostContainer = nsView as? HostContainerView
        let hostOwnsPortalNow = hostContainer.map { host in
            terminalSurface.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                instanceSerial: host.instanceSerial,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        } ?? true

        // Keep the surface lifecycle and handlers updated even if we defer re-parenting.
        hostedView.attachSurface(terminalSurface)
        hostedView.setFocusHandler { onFocus?(terminalSurface.id) }
        hostedView.setTriggerFlashHandler(onTriggerFlash)
        if hostOwnsPortalNow {
            hostedView.setPaneDropContext(TerminalPaneDropContext(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                paneId: paneId
            ))
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
            hostedView.setNotificationRing(visible: showsUnreadNotificationRing)
            hostedView.setSearchOverlay(searchState: searchState)
            hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        }
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
        func portalBindingStillLive() -> Bool {
            terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: portalExpectedSurfaceId,
                expectedGeneration: portalExpectedGeneration
            )
        }
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            cmuxDebugLog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            cmuxDebugLog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        if hostOwnsPortalNow {
            hostedView.setDropZoneOverlay(zone: forwardedDropZone)
        }

        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "didMoveToWindow"
                ) else { return }
                guard host.window != nil else { return }
                guard portalBindingStillLive() else { return }
                TerminalWindowPortalRegistry.bind(
                    hostedView: hostedView,
                    to: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority,
                    expectedSurfaceId: portalExpectedSurfaceId,
                    expectedGeneration: portalExpectedGeneration,
                    deferLayoutSynchronization: true
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "geometryChanged"
                ) else { return }
                guard portalBindingStillLive() else { return }
                let hostId = ObjectIdentifier(host)
                if host.window != nil,
                   (coordinator.lastBoundHostId != hostId ||
                    !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)) {
#if DEBUG
                    cmuxDebugLog(
                        "ws.hostState.rebindOnGeometry surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                    hostedView.setActive(coordinator.desiredIsActive)
                    hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
                }
                Self.synchronizePortalGeometry(
                    for: host,
                    coordinator: coordinator
                )
            }

            if host.window != nil, hostOwnsPortalNow {
                let portalBindingLive = portalBindingStillLive()
                let hostId = ObjectIdentifier(host)
                let geometryRevision = host.geometryRevision
                let portalEntryMissing = !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
                // Notification rings are hosted inside GhosttySurfaceScrollView and update in place.
                // A ring-only state change must not resynchronize the window portal while SwiftUI is
                // invalidating notification UI, or the terminal can be hidden until the next tab switch.
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    portalEntryMissing ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredPortalZPriority != portalZPriority
                if portalBindingLive && shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        cmuxDebugLog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
                } else if portalBindingLive && coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                    Self.synchronizePortalGeometry(
                        for: host,
                        coordinator: coordinator
                    )
                }
            } else if hostOwnsPortalNow, portalBindingStillLive() {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
#if DEBUG
                if desiredStateChanged {
                    cmuxDebugLog(
                        "ws.hostState.deferBind surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=hostNoWindow visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority) " +
                        "hostedWindow=\(hostedView.window != nil ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                    )
                }
#endif
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }
        }

        let hostWindowAttached = hostContainer?.window != nil
        let isBoundToCurrentHost = hostContainer.map { host in
            TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
        } ?? true
        let shouldApplyImmediateHostedState = hostOwnsPortalNow && Self.shouldApplyImmediateHostedStateUpdate(
            desiredVisibleInUI: isVisibleInUI,
            hostedViewHasSuperview: hostedView.superview != nil,
            isBoundToCurrentHost: isBoundToCurrentHost
        )

        if portalBindingStillLive() && shouldApplyImmediateHostedState {
            hostedView.setVisibleInUI(isVisibleInUI)
            hostedView.setActive(isActive)
        } else {
            // Preserve portal entry visibility while a stale host is still receiving SwiftUI updates.
            // The currently bound host remains authoritative for immediate visible/active state.
#if DEBUG
            if desiredStateChanged {
                cmuxDebugLog(
                    "ws.hostState.deferApply surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=\(hostOwnsPortalNow ? "staleHostBinding" : "hostOwnershipRejected") " +
                    "hostWindow=\(hostWindowAttached ? 1 : 0) " +
                    "boundToCurrent=\(isBoundToCurrentHost ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0)"
                )
            }
#endif
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        let hostedView = coordinator.hostedView
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        // SwiftUI can transiently dismantle/rebuild NSViewRepresentable instances during split
        // tree updates. Do not drop the portal lease or force visible/active false here; that
        // causes avoidable blackouts when the same hosted view is rebound moments later.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

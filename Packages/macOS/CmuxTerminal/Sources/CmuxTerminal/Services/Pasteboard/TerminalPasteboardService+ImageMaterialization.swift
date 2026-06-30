public import AppKit
public import CmuxTerminalCore
internal import UniformTypeIdentifiers
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalPasteboardService: TerminalImagePasteWriting {
    /// Attempts to materialize a decodable pasteboard image into a temporary file.
    /// `rejectedImagePayload` means a real image was found but could not be used,
    /// so callers should not fall back to auxiliary plain text or URLs.
    public func materializeImageFileURLIfNeeded(
        from pasteboard: NSPasteboard = .general
    ) -> TerminalImageFileMaterialization {
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

    /// Materializes every decodable pasteboard image into temporary files.
    public func materializeImageFileURLsIfNeeded(
        from pasteboard: NSPasteboard = .general
    ) -> TerminalImageFileListMaterialization {
        materializeImageFileURLs(from: imageRepresentations(in: pasteboard))
    }

    /// When the pasteboard has no paste text (or `assumeNoText` is set),
    /// materializes every image and returns the file URLs; empty otherwise.
    public func saveImageFileURLsIfNeeded(
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
    public func saveImageFileURLIfNeeded(
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
    public func saveClipboardImageIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> String? {
        saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: assumeNoText)
            .map(\.path.terminalShellEscaped)
    }

    /// Writes raw image bytes forwarded from a remote client (e.g. an image
    /// pasted on the paired iOS app) to a temporary file and returns its
    /// shell-escaped path, ready to inject as terminal input exactly the way
    /// ``saveClipboardImageIfNeeded(from:assumeNoText:)`` does for a local paste.
    ///
    /// Returns `nil` when the payload is empty, exceeds the 10 MB clipboard-image
    /// cap, or cannot be written. The temp file is registered as owned so the
    /// usual cleanup paths reclaim it.
    public func saveImageData(_ data: Data, fileExtension: String) -> String? {
        guard !data.isEmpty, data.count <= Self.maxClipboardImageSize else { return nil }

        let fileURL = temporaryImageFileURL(fileExtension: sanitizedImageFileExtension(fileExtension))
        do {
            try data.write(to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        registerOwnedTemporaryImageFile(fileURL)
        return fileURL.path.terminalShellEscaped
    }
}

extension TerminalPasteboardService {
    private func materializeImageFileURLs(
        from representations: [(data: Data, fileExtension: String)]
    ) -> TerminalImageFileListMaterialization {
        guard !representations.isEmpty else { return .noDecodableImagePayload }

        var fileURLs: [URL] = []
        for representation in representations {
            guard representation.data.count <= Self.maxClipboardImageSize else {
#if DEBUG
                logDebugEvent("terminal.paste.image.rejected reason=tooLarge bytes=\(representation.data.count)")
#endif
                cleanupTransferredTemporaryImageFiles(fileURLs)
                return .rejectedImagePayload
            }

            let fileURL = temporaryImageFileURL(fileExtension: representation.fileExtension)

            do {
                try representation.data.write(to: fileURL)
            } catch {
#if DEBUG
                logDebugEvent("terminal.paste.image.writeFailed error=\(error.localizedDescription)")
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

    private func temporaryImageFileURL(fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "\(Self.temporaryImageFilenamePrefix)\(timestamp)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        return temporaryDirectory.appendingPathComponent(filename)
    }

    /// Constrains a client-supplied image extension to a known-good lowercase
    /// token, defaulting to `png`, so the temp filename can never carry path
    /// separators or other hostile characters.
    private func sanitizedImageFileExtension(_ raw: String) -> String {
        let token = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        return allowed.contains(token) ? token : "png"
    }
}

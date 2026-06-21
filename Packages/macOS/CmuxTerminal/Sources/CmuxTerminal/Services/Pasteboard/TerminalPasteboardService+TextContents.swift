public import AppKit
public import CmuxTerminalCore
public import GhosttyKit
internal import UniformTypeIdentifiers

extension TerminalPasteboardService: TerminalClipboardReading {
    /// The terminal-paste text for the pasteboard's current contents,
    /// applying cmux's flavor-priority rules.
    public func stringContents(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []

        if (types.contains(.fileURL) || types.contains(.URL)),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? $0.path.terminalShellEscaped : $0.absoluteString }
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

    /// Whether the location's pasteboard currently holds pasteable contents.
    public func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return hasPasteableContents(in: pasteboard)
    }

    /// The best plain-text flavor only, bypassing rich-text resolution.
    public func fallbackPlainTextContents(from pasteboard: NSPasteboard) -> String? {
        plainTextContents(from: pasteboard)
    }
}

extension TerminalPasteboardService {
    private func attributedStringContents(
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
            .split(separator: Self.objectReplacementCharacter, omittingEmptySubsequences: false)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let sanitized, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private func richTextContents(from pasteboard: NSPasteboard) -> String? {
        if let htmlText = attributedStringContents(from: pasteboard, type: .html, documentType: .html) {
            return htmlText
        }
        if let rtfText = attributedStringContents(from: pasteboard, type: .rtf, documentType: .rtf) {
            return rtfText
        }
        return attributedStringContents(from: pasteboard, type: .rtfd, documentType: .rtfd)
    }

    private func plainTextContents(from pasteboard: NSPasteboard) -> String? {
        let allTypes = pasteboard.types ?? []

        // Prefer UTF-8 plain text whenever available. Some apps — notably
        // Qt-based ones like Telegram Desktop — register
        // `com.apple.traditional-mac-plain-text` (Mac OS Roman, which cannot
        // represent non-Latin scripts) *before* the UTF-8 variants. Iterating
        // `pasteboard.types` in order then returns a lossy value where every
        // non-Latin character becomes "?". Fixes #2818.
        for preferred in [Self.utf8PlainTextType, NSPasteboard.PasteboardType.string] {
            guard allTypes.contains(preferred) else { continue }
            guard let value = pasteboard.string(forType: preferred), !value.isEmpty else { continue }
            return value
        }

        for type in allTypes {
            if type == Self.utf8PlainTextType || type == .string { continue }
            guard isPlainTextType(type) else { continue }
            guard let value = pasteboard.string(forType: type), !value.isEmpty else { continue }
            return value
        }

        return nil
    }

    private func hasPasteableContents(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.URL) || types.contains(.html) || types.contains(.rtf) || types.contains(.rtfd) {
            return true
        }
        if types.contains(where: isPlainTextType) {
            return true
        }
        return hasImageData(in: pasteboard)
    }

    private func isPlainTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string || type == Self.utf8PlainTextType {
            return true
        }

        guard type != .html,
              type != .rtf,
              type != .rtfd,
              type != .fileURL,
              let utType = UTType(type.rawValue) else { return false }

        return utType.conforms(to: .plainText)
    }

    private func isRichTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .html || type == .rtf || type == .rtfd
    }

    func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }

        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    func attributedString(
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

    func attributedString(
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
}

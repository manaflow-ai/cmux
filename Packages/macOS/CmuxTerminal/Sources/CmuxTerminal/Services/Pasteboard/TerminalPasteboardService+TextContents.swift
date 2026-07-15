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

    /// Rewrites the terminal's text representations after copy reflow.
    ///
    /// Existing plain-text, HTML, and RTF flavors are retained. Rich flavors
    /// are edited to match `string` while preserving attributes on surviving
    /// content, so paste destinations cannot select stale hard-wrapped text.
    ///
    /// - Parameters:
    ///   - string: The transformed text to publish through every text flavor.
    ///   - pasteboard: The terminal pasteboard whose existing flavors are updated.
    /// - Returns: `true` when every advertised text representation was updated.
    @discardableResult
    public func rewriteTextRepresentations(_ string: String, in pasteboard: NSPasteboard) -> Bool {
        let existingTypes = pasteboard.types ?? []
        let richFormats: [(
            pasteboardType: NSPasteboard.PasteboardType,
            documentType: NSAttributedString.DocumentType
        )] = [
            (.html, .html),
            (.rtf, .rtf),
        ]
        var richReplacements: [(type: NSPasteboard.PasteboardType, data: Data)] = []

        for format in richFormats where existingTypes.contains(format.pasteboardType) {
            guard let attributed = attributedString(
                from: pasteboard,
                type: format.pasteboardType,
                documentType: format.documentType
            ),
                  let rewritten = attributedString(attributed, replacingTextWith: string),
                  let data = try? rewritten.data(
                      from: NSRange(location: 0, length: rewritten.length),
                      documentAttributes: [
                          .documentType: format.documentType,
                          .characterEncoding: String.Encoding.utf8.rawValue,
                      ]
                  ) else { return false }
            richReplacements.append((format.pasteboardType, data))
        }

        var plainTextTypes = existingTypes.filter(isPlainTextType)
        if !plainTextTypes.contains(.string) {
            plainTextTypes.append(.string)
        }

        var wroteEveryRepresentation = true
        for type in plainTextTypes {
            wroteEveryRepresentation = pasteboard.setString(string, forType: type)
                && wroteEveryRepresentation
        }
        for replacement in richReplacements {
            wroteEveryRepresentation = pasteboard.setData(replacement.data, forType: replacement.type)
                && wroteEveryRepresentation
        }
        return wroteEveryRepresentation
    }
}

extension TerminalPasteboardService {
    /// Replaces text while retaining attributes on every surviving non-whitespace token.
    /// Reflow only removes tokens and rewrites whitespace; if a future transform
    /// inserts non-whitespace content, alignment fails and the pasteboard rewrite
    /// is aborted before any representation is changed.
    private func attributedString(
        _ attributed: NSAttributedString,
        replacingTextWith replacement: String
    ) -> NSAttributedString? {
        guard let edits = textEdits(from: attributed.string, to: replacement) else { return nil }
        let rewritten = NSMutableAttributedString(attributedString: attributed)
        for edit in edits.reversed() {
            rewritten.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        guard rewritten.string == replacement else { return nil }
        return rewritten
    }

    /// Produces a linear edit plan by aligning non-whitespace tokens in order.
    /// Gaps between aligned tokens contain the newlines, indentation, padding,
    /// and decorations that copy reflow is allowed to remove or normalize.
    private func textEdits(
        from source: String,
        to target: String
    ) -> [(range: NSRange, replacement: String)]? {
        var sourceSearchIndex = source.startIndex
        var targetSearchIndex = target.startIndex
        var sourceGapStart = source.startIndex
        var targetGapStart = target.startIndex
        var edits: [(range: NSRange, replacement: String)] = []

        while let targetToken = nextNonWhitespaceToken(
            in: target,
            searchIndex: &targetSearchIndex
        ) {
            var matchingSourceToken: Range<String.Index>?
            while let sourceToken = nextNonWhitespaceToken(
                in: source,
                searchIndex: &sourceSearchIndex
            ) {
                if source[sourceToken] == target[targetToken] {
                    matchingSourceToken = sourceToken
                    break
                }
            }
            guard let matchingSourceToken else { return nil }
            let sourceGap = sourceGapStart..<matchingSourceToken.lowerBound
            let targetGap = targetGapStart..<targetToken.lowerBound
            if source[sourceGap] != target[targetGap] {
                edits.append((NSRange(sourceGap, in: source), String(target[targetGap])))
            }
            sourceGapStart = matchingSourceToken.upperBound
            targetGapStart = targetToken.upperBound
        }

        let sourceGap = sourceGapStart..<source.endIndex
        let targetGap = targetGapStart..<target.endIndex
        if source[sourceGap] != target[targetGap] {
            edits.append((NSRange(sourceGap, in: source), String(target[targetGap])))
        }
        return edits
    }

    private func nextNonWhitespaceToken(
        in string: String,
        searchIndex: inout String.Index
    ) -> Range<String.Index>? {
        while searchIndex < string.endIndex, string[searchIndex].isWhitespace {
            searchIndex = string.index(after: searchIndex)
        }
        guard searchIndex < string.endIndex else { return nil }
        let start = searchIndex
        while searchIndex < string.endIndex, !string[searchIndex].isWhitespace {
            searchIndex = string.index(after: searchIndex)
        }
        return start..<searchIndex
    }

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

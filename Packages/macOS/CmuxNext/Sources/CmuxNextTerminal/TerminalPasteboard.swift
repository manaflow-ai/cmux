import AppKit

/// Pasteboard access shared by clipboard callbacks, paste, and drops.
enum TerminalPasteboard {
    static let selectionName = NSPasteboard.Name("com.cmuxterm.next.selection")

    static func pasteboard(_ location: TerminalPasteboardLocation) -> NSPasteboard {
        switch location {
        case .standard: .general
        case .selection: NSPasteboard(name: selectionName)
        }
    }

    static func write(_ items: [TerminalClipboardItem], to location: TerminalPasteboardLocation) {
        let pasteboard = pasteboard(location)
        var types: [NSPasteboard.PasteboardType] = []
        for item in items {
            if item.mime.hasPrefix("text/html") {
                types.append(.html)
            } else if item.mime.hasPrefix("text/plain") {
                types.append(.string)
            }
        }
        guard !types.isEmpty else { return }
        pasteboard.declareTypes(types, owner: nil)
        for item in items {
            if item.mime.hasPrefix("text/html") {
                pasteboard.setString(item.text, forType: .html)
            } else if item.mime.hasPrefix("text/plain") {
                pasteboard.setString(item.text, forType: .string)
            }
        }
    }

    /// Text to paste: file URLs become shell-escaped paths, then URLs, then
    /// plain strings. Line endings become LF so Ghostty's unsafe-paste check
    /// sees every line break before an unbracketed paste can submit it.
    static func pasteText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return normalizedLineEndings(urls.map { shellEscaped($0.path) }.joined(separator: " "))
        }
        if let string = pasteboard.string(forType: .string) {
            return normalizedLineEndings(string)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return normalizedLineEndings(urls.map(\.absoluteString).joined(separator: " "))
        }
        return nil
    }

    /// ``pasteText(from:)`` on contents already read (same order).
    static func pasteText(from contents: TerminalPasteboardContents) -> String? {
        if !contents.fileURLs.isEmpty {
            return normalizedLineEndings(contents.fileURLs.map { shellEscaped($0.path) }.joined(separator: " "))
        }
        if let string = contents.string { return normalizedLineEndings(string) }
        if !contents.urls.isEmpty {
            return normalizedLineEndings(contents.urls.map(\.absoluteString).joined(separator: " "))
        }
        return nil
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Backslash-escapes characters the shell would interpret, matching what
    /// Ghostty inserts for a dropped file.
    static func shellEscaped(_ path: String) -> String {
        let special: Set<Character> = [" ", "\\", "\t", "\n", "\r", "'", "\"", "`", "!", "$", "&", "*", "(", ")", "[", "]", "{", "}", "<", ">", "|", ";", "?", "#", "~", "="]
        var result = ""
        result.reserveCapacity(path.count)
        for character in path {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

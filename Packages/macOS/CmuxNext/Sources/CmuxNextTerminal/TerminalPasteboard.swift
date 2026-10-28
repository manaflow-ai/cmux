import AppKit
import CmuxNextCompat

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
            return escapedPaths(urls)
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
            return escapedPaths(contents.fileURLs)
        }
        if let string = contents.string { return normalizedLineEndings(string) }
        if !contents.urls.isEmpty {
            return normalizedLineEndings(contents.urls.map(\.absoluteString).joined(separator: " "))
        }
        return nil
    }

    /// The files' shell-escaped paths, space-separated; nil when a path holds a control character,
    /// which no escaping keeps from acting when typed (Ctrl-U erases the line, CR runs it: Ghostty
    /// 1.4.0, 0c234a04d).
    private static func escapedPaths(_ files: [URL]) -> String? {
        let paths = files.map(\.path)
        guard !paths.contains(where: \.containsTerminalControlCharacter) else { return nil }
        return normalizedLineEndings(paths.map(shellEscaped).joined(separator: " "))
    }

    /// `text` with CRLF and CR as LF, so Ghostty's unsafe-paste check (LF only in this pin) sees a
    /// carriage return as the line break it is (Ghostty 1.4.0, 5c9a3d8a9).
    static func normalizedLineEndings(_ text: String) -> String {
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

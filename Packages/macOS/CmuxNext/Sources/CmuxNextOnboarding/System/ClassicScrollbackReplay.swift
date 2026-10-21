public import Foundation

/// A classic terminal's saved scrollback as a file its new shell prints once
/// above its first prompt (`CMUX_RESTORE_SCROLLBACK_FILE`, read by the shell
/// layer in `Resources/cmux-cli-path`). The text is read-only output: only
/// printable text, line breaks, tabs and color (SGR) sequences come back, so a
/// saved title, clipboard, hyperlink or mode change never runs again.
public nonisolated struct ClassicScrollbackReplay: Sendable {
    /// Classic's own limits for a restored terminal.
    static let maxCharacters = 400_000
    static let maxLines = 4000

    /// The output to print: the newest lines within the limits, ending on a
    /// fresh line with colors reset.
    public let text: String

    /// Nil when nothing printable is left of `scrollback`.
    public init?(_ scrollback: String) {
        var lines = Self.printable(scrollback).split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        var kept = lines.suffix(Self.maxLines)
        var count = kept.reduce(0) { $0 + $1.count + 1 }
        while count > Self.maxCharacters, kept.count > 1 { count -= kept.removeFirst().count + 1 }
        let body = kept.joined(separator: "\n")
        let text = body.count > Self.maxCharacters ? String(body.suffix(Self.maxCharacters)) : body
        // Reset before (a cut sequence) and after (a color still on).
        self.text = "\u{1b}[0m" + text + "\u{1b}[0m\n"
    }

    /// Writes `text` to a new file only this user can read, in a folder only
    /// this user can open, under `directory` (the user's temporary folder).
    public func write(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory.appendingPathComponent("cmux-next-scrollback", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }

    /// Printable text, `\n`, tabs and SGR sequences; `\r\n` becomes `\n`.
    /// Every other control character and escape sequence is dropped.
    private static func printable(_ scrollback: String) -> String {
        let scalars = scrollback.unicodeScalars
        var out = String.UnicodeScalarView()
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            scalars.formIndex(after: &index)
            switch scalar.value {
            case 0x0A, 0x09:
                out.append(scalar)
            case 0x1B:
                index = escape(scalars, from: index, into: &out)
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Skips the escape sequence after an ESC at `start - 1`, keeping it in
    /// `out` only when it is SGR; returns where the text resumes.
    private static func escape(
        _ scalars: String.UnicodeScalarView,
        from start: String.UnicodeScalarView.Index,
        into out: inout String.UnicodeScalarView
    ) -> String.UnicodeScalarView.Index {
        guard start < scalars.endIndex else { return start }
        switch scalars[start] {
        case "[":
            // CSI: parameters and intermediates, then one final byte.
            var end = scalars.index(after: start)
            while end < scalars.endIndex, (0x20...0x3F).contains(scalars[end].value) {
                scalars.formIndex(after: &end)
            }
            guard end < scalars.endIndex, (0x40...0x7E).contains(scalars[end].value) else { return end }
            let parameters = scalars[scalars.index(after: start)..<end]
            if scalars[end] == "m", parameters.allSatisfy({ (0x30...0x3B).contains($0.value) }) {
                out.append("\u{1b}")
                out.append(contentsOf: scalars[start...end])
            }
            return scalars.index(after: end)
        case "]", "P", "X", "^", "_":
            // OSC, DCS, SOS, PM, APC: a string up to BEL or ST (`ESC \`).
            var end = scalars.index(after: start)
            while end < scalars.endIndex {
                if scalars[end] == "\u{07}" { return scalars.index(after: end) }
                // ST ends it; another ESC ends it and starts its own sequence.
                if scalars[end] == "\u{1b}" {
                    let next = scalars.index(after: end)
                    return next < scalars.endIndex && scalars[next] == "\\" ? scalars.index(after: next) : end
                }
                scalars.formIndex(after: &end)
            }
            return end
        default:
            // Intermediates, then one final character (charset, keypad, save cursor, ...).
            var end = start
            while end < scalars.endIndex, (0x20...0x2F).contains(scalars[end].value) {
                scalars.formIndex(after: &end)
            }
            return end < scalars.endIndex ? scalars.index(after: end) : end
        }
    }
}

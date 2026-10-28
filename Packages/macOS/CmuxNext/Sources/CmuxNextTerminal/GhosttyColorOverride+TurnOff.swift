import CmuxNextCompat
public import Foundation

/// The Theme section's Let Themes Set Colors: turns off the color lines of the user's Ghostty
/// config that no theme can change, so the theme sets those colors. Each line becomes a comment
/// that keeps its old value, so the person can turn it on again by hand. A file is written in
/// place (through a symlink, keeping its mode and hard links). File I/O: call off the main thread.
nonisolated extension GhosttyColorOverride {
    /// The comment put before each turned-off line.
    public static let turnedOffMarker = "# Turned off by cmux so themes can set this color:"

    /// Comments out every line in the overrides' files that sets one of their keys (all
    /// `palette` lines, not only the last). Returns the files it changed.
    @discardableResult
    public static func turnOff(_ overrides: [GhosttyColorOverride]) throws -> [URL] {
        var keysByFile: [URL: Set<String>] = [:]
        for override in overrides {
            keysByFile[URL(fileURLWithPath: override.file).resolvingSymlinksInPath(), default: []].insert(override.key)
        }
        var changed: [URL] = []
        for (file, keys) in keysByFile.sorted(by: { $0.key.path < $1.key.path }) {
            let text = try String(blockingContentsOf: file, encoding: .utf8)
            let edited = commentingOut(keys, in: text)
            guard edited != text else { continue }
            try Data(edited.utf8).blockingWrite(to: file)
            changed.append(file)
        }
        return changed
    }

    /// `text` with each line that sets one of `keys` turned into the marker and the line as a
    /// comment. Lines as Ghostty reads them: trimmed, `#` starts a comment, `key = value`.
    static func commentingOut(_ keys: Set<String>, in text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let ending = raw.hasSuffix("\r") ? "\r" : ""
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "="),
                  keys.contains(line[..<equals].trimmingCharacters(in: .whitespaces)) else {
                lines.append(raw)
                continue
            }
            lines.append(turnedOffMarker + ending)
            lines.append("# " + line + ending)
        }
        return lines.joined(separator: "\n")
    }
}

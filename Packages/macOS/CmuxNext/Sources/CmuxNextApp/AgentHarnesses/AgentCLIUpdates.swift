import CmuxNextSettings
import Foundation

/// One-click agent CLI updates (cx-ny85): the lines Settings > Agents (Update, Update All) and the
/// palette's Update Agent CLIs type into a terminal tab, from the daemon's `_acpmux/harness/health`
/// rows. Each word is single-quoted; an update that needs sudo is never typed (Settings shows its
/// command for the person to run).
nonisolated enum AgentCLIUpdates {
    /// Programs that raise rights; never typed, whatever the daemon says.
    private static let elevating: Set<String> = ["sudo", "doas", "su", "pkexec"]

    /// The rows of a `_acpmux/harness/health` answer by harness id; nil when it is not one.
    static func rows(_ data: Data) -> [String: JSONValue]? {
        guard let rows = (try? JSONValue.parse(data))?["harnesses"]?.arrayValue else { return nil }
        return Dictionary(rows.compactMap { row in row["id"]?.stringValue.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The line that updates one health row: nil when it is not outdated, needs sudo (or does not
    /// say), runs a program that raises rights, or holds a character no shell quotes alike.
    static func line(_ row: JSONValue) -> String? {
        guard row["outdated"]?.boolValue == true, let plan = row["update"], plan["elevated"]?.boolValue == false,
              let argv = plan["argv"]?.arrayValue?.compactMap(\.stringValue), let program = argv.first,
              !elevating.contains((program as NSString).lastPathComponent) else { return nil }
        let unsafe: (Character) -> Bool = { character in
            character == "'" || character == "\\" || character.isNewline
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        guard !argv.contains(where: { $0.contains(where: unsafe) }) else { return nil }
        return argv.map { "'" + $0 + "'" }.joined(separator: " ")
    }

    /// Update All: every row's line once, in order, each running whether the one before failed;
    /// nil when none can be typed.
    static func allLine(_ rows: [JSONValue]) -> String? {
        var lines: [String] = []
        for row in rows { if let line = line(row), !lines.contains(line) { lines.append(line) } }
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }
}

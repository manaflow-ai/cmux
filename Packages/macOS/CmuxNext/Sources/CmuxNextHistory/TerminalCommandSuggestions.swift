public import Foundation

/// A repeated, successful command that can be reviewed as a reusable action.
public nonisolated struct TerminalCommandSuggestion: Hashable, Identifiable, Sendable {
    public let machine: String
    public let command: String
    public let cwd: String
    public let count: Int
    public let lastRunAt: Date

    public var id: String { TerminalCommandSuggestionStore.key(machine: machine, cwd: cwd, command: command) }

    public init(machine: String, command: String, cwd: String, count: Int, lastRunAt: Date) {
        self.machine = machine
        self.command = command
        self.cwd = cwd
        self.count = count
        self.lastRunAt = lastRunAt
    }
}

/// In-memory frequency store for the first command-action dogfood slice.
/// The daemon remains the durable source of command rows; this is a bounded
/// projection rebuilt after refresh and never sent to analytics or models.
public nonisolated struct TerminalCommandSuggestionStore: Sendable {
    public struct Policy: Sendable, Hashable {
        public var minimumCount: Int
        public var maximumRecords: Int
        public var maximumSuggestions: Int

        public init(minimumCount: Int = 3, maximumRecords: Int = 1_000, maximumSuggestions: Int = 20) {
            self.minimumCount = max(1, minimumCount)
            self.maximumRecords = max(1, maximumRecords)
            self.maximumSuggestions = max(1, maximumSuggestions)
        }
    }

    public let policy: Policy
    private var records: [String: TerminalCommand] = [:]
    private var dismissed: Set<String> = []
    private var clearedThrough: Date?

    public init(policy: Policy = Policy()) { self.policy = policy }

    public mutating func replace(_ commands: [TerminalCommand]) {
        records.removeAll(keepingCapacity: true)
        for command in commands where Self.isEligible(command)
            && (clearedThrough.map { command.startedAt > $0 } ?? true) {
            records[command.qualifiedID] = command
        }
        trim()
    }

    public mutating func record(_ command: TerminalCommand) {
        guard Self.isEligible(command), clearedThrough.map({ command.startedAt > $0 }) ?? true else { return }
        records[command.qualifiedID] = command
        trim()
    }

    /// Exact machine and directory scope, ranked by frequency and recency.
    public func suggestions(machine: String, cwd: String) -> [TerminalCommandSuggestion] {
        guard !machine.isEmpty, !cwd.isEmpty else { return [] }
        let grouped = Dictionary(grouping: records.values.filter { $0.machine == machine && $0.cwd == cwd }) {
            Self.key(machine: $0.machine, cwd: $0.cwd ?? "", command: $0.command ?? "")
        }
        return grouped.compactMap { key, rows in
            guard rows.count >= policy.minimumCount, !dismissed.contains(key),
                  let first = rows.first, let command = first.command, let rowCWD = first.cwd else { return nil }
            return TerminalCommandSuggestion(machine: machine, command: command, cwd: rowCWD,
                                             count: rows.count, lastRunAt: rows.map(\.startedAt).max() ?? first.startedAt)
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastRunAt != $1.lastRunAt { return $0.lastRunAt > $1.lastRunAt }
            return $0.command < $1.command
        }
        .prefix(policy.maximumSuggestions)
        .map { $0 }
    }

    public mutating func dismiss(_ suggestion: TerminalCommandSuggestion) { dismissed.insert(suggestion.id) }

    public mutating func clear() {
        clearedThrough = records.values.map(\.startedAt).max() ?? Date()
        records.removeAll(keepingCapacity: true)
        dismissed.removeAll(keepingCapacity: true)
    }

    /// Returns a reviewed cmux.json fragment. It is a preview only; callers
    /// must ask before writing it to a configuration file.
    public func exportAction(_ suggestion: TerminalCommandSuggestion, name: String? = nil) -> String {
        let actionName = name.flatMap(Self.actionName) ?? Self.actionName(suggestion.command) ?? "suggested-action"
        let title = "Run \(suggestion.command)"
        let command = "cd -- \(Self.shellQuote(suggestion.cwd)) && \(suggestion.command)"
        return """
        {
          "actions": {
            "\(Self.jsonQuote(actionName))": {
              "type": "command",
              "title": "\(Self.jsonQuote(title))",
              "command": "\(Self.jsonQuote(command))",
              "target": "newTabInCurrentPane"
            }
          }
        }
        """
    }

    /// Unknown results, leading-space entries, likely secrets, and risky
    /// destructive/network patterns never qualify.
    public static func isEligible(_ command: TerminalCommand) -> Bool {
        guard command.exitCode == 0,
              let text = command.command, !text.isEmpty,
              let cwd = command.cwd, !cwd.isEmpty,
              text.first?.isWhitespace != true else { return false }
        let lower = text.lowercased()
        let secretMarkers = ["password=", "passwd=", "token=", "secret=", "api_key=", "apikey=",
                             "authorization:", "bearer ", "api-key", "aws_secret_access_key", "aws_session_token",
                             "client_secret", "private_key", "refresh_token", "-----begin"]
        let normalized = lower.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let riskyPatterns = ["rm -rf", "rm -r ", "git reset --hard", "git push --force", "sudo ",
                             "curl |", "curl -s |", "wget |", "| sh", "| bash", "| zsh", "| /bin/sh",
                             "| /bin/bash"]
        let hasURLCredentials = ["http://", "https://"].contains { scheme in
            guard let schemeStart = lower.range(of: scheme)?.upperBound else { return false }
            let authority = lower[schemeStart...].split(whereSeparator: { "/?#".contains($0) }).first ?? ""
            guard let at = authority.lastIndex(of: "@") else { return false }
            return authority[..<at].contains(":")
        }
        return !secretMarkers.contains(where: lower.contains)
            && !hasURLCredentials
            && !riskyPatterns.contains(where: normalized.contains)
    }

    fileprivate static func key(machine: String, cwd: String, command: String) -> String {
        [machine, cwd, command].joined(separator: "\u{0}")
    }

    private mutating func trim() {
        guard records.count > policy.maximumRecords else { return }
        let keep = records.values.sorted { $0.startedAt > $1.startedAt }.prefix(policy.maximumRecords)
        records = Dictionary(uniqueKeysWithValues: keep.map { ($0.qualifiedID, $0) })
    }

    private static func actionName(_ raw: String) -> String? {
        let slug = String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .split(separator: "-").joined(separator: "-"))
        guard !slug.isEmpty else { return nil }
        return "suggested-\(slug.prefix(48))"
    }

    private static func shellQuote(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func jsonQuote(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

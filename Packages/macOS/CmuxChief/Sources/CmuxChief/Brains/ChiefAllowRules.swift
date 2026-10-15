import Foundation

/// The user's "Always Allow" rules: a program and its subcommand ("cmux tree",
/// "git push") that an approval card's menu allowed from now on.
///
/// Stored in the Chief home as `state/allow-rules.json` (`{"rules":[["cmux","tree"]]}`).
/// ``ChiefToolPolicy/autoAllowsCommand(_:)`` consults them per simple command,
/// after the line-level checks (no substitution, no `$` expansion, limited
/// redirects), so a rule never lets a pipeline smuggle another program in.
/// A rule never covers a `cmux` call that names a destructive verb
/// (``ChiefToolPolicy/cmuxApprovalWords``), and no rule is made for a shell, an
/// interpreter or a deleting program (``prefix(for:)``; Home's card offers the
/// same rule, `ChiefRows.alwaysAllowWords` in MessagesLabHome: change both).
public final class ChiefAllowRules: @unchecked Sendable {
    /// The process's rules (the brains' policy checks are static).
    public static let shared = ChiefAllowRules()

    private let lock = NSLock()
    private var file: URL?
    private var rules: [[String]] = []

    public init() {}

    private struct Stored: Codable {
        var rules: [[String]]
    }

    /// Reads `home`'s rules (once per home; a missing or unreadable file is no rules).
    public func load(_ home: ChiefHome) {
        let url = home.stateDirectory.appendingPathComponent("allow-rules.json", isDirectory: false)
        lock.lock()
        defer { lock.unlock() }
        guard file != url else { return }
        file = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        rules = (stored?.rules ?? []).filter { $0.count == 2 }
    }

    /// The rules now.
    public var all: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    /// Whether one simple command (quotes removed) starts with a rule's words.
    func allows(_ words: [String]) -> Bool {
        guard words.count >= 2 else { return false }
        if words.first == "cmux", words.contains(where: { ChiefToolPolicy.cmuxApprovalWords.contains($0.lowercased()) }) {
            return false
        }
        let head = Array(words.prefix(2))
        return all.contains(head)
    }

    /// Saves the rule for `command` and returns its words; nil when no rule is offered for it.
    ///
    /// - Throws: A file error when the rules cannot be written (the rule still holds for this session).
    @discardableResult
    public func add(command: String) throws -> [String]? {
        guard let words = Self.prefix(for: command) else { return nil }
        lock.lock()
        if !rules.contains(words) { rules.append(words) }
        let snapshot = rules
        let url = file
        lock.unlock()
        guard let url else { return words }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Stored(rules: snapshot)).write(to: url, options: .atomic)
        return words
    }

    /// The rule words for `command`: its program and subcommand, only for one plain simple
    /// command (no pipes, lists, redirects, quotes, globs or expansion), never for a shell, an
    /// interpreter or a deleting program.
    public static func prefix(for command: String) -> [String]? {
        let banned = CharacterSet(charactersIn: "|&;<>`$(){}\\\"'*?\n\t")
        guard command.rangeOfCharacter(from: banned) == nil else { return nil }
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2, let program = words.first, let sub = words.dropFirst().first else { return nil }
        let refused: Set<String> = ["sh", "bash", "zsh", "fish", "sudo", "env", "xargs", "eval", "exec", "python", "python3",
                                    "node", "ruby", "perl", "osascript", "rm", "dd", "mv", "chmod", "chown", "kill", "killall"]
        guard !refused.contains(program), program.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil,
              sub.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { return nil }
        if program == "cmux", ChiefToolPolicy.cmuxApprovalWords.contains(sub) { return nil }
        return [program, sub]
    }

    /// The command of a "Run `<command>`?" approval prompt (``ChiefToolPolicy/claudePrompt(_:input:)``).
    public static func command(inPrompt prompt: String) -> String? {
        guard prompt.hasPrefix("Run `") else { return nil }
        let rest = prompt.dropFirst("Run `".count)
        guard let end = rest.lastIndex(of: "`") else { return nil }
        let command = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

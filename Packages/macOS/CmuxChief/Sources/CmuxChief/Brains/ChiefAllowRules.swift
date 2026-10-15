import Foundation

/// The user's "Always Allow" rules: a program and its subcommand ("cmux tree",
/// "git push") that an approval card's menu allowed from now on.
///
/// Stored in the Chief home as `state/allow-rules.json` (`{"rules":[["cmux","tree"]]}`).
/// ``ChiefToolPolicy/autoAllowsCommand(_:)`` consults them per simple command,
/// after the line-level checks (no substitution, no `$` expansion, limited
/// redirects), so a rule never lets a pipeline smuggle another program in.
/// A rule never covers a `cmux` call with a word that asks
/// (``ChiefToolPolicy/cmuxWordAsks(_:)``: destructive verbs and their
/// `close-`/`kill-` prefixes, `send*`, `exec`, `run`, `--force`, `--command`), and
/// no rule is made, or honored when read from disk, for a shell, an
/// interpreter, a deleting program, `git config`, `npx`, `npm exec|run`,
/// `make`, or the `cmux` groups that run commands or answer for the user
/// (`vm`, `cloud`, `chief`, `browser`, `send*`; ``isEligible(program:subcommand:)``).
/// Home's card offers the same rule (`ChiefRows.alwaysAllowWords` in
/// MessagesLabHome: change both).
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

    /// Reads `home`'s rules and saves new ones there (once per home; a missing or unreadable file is
    /// no rules). The app has one Chief home; rules read from another home are kept (never dropped).
    public func load(_ home: ChiefHome) {
        let url = home.stateDirectory.appendingPathComponent("allow-rules.json", isDirectory: false)
        lock.lock()
        defer { lock.unlock() }
        guard file != url else { return }
        file = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        for rule in stored?.rules ?? [] where (2...3).contains(rule.count) && !rules.contains(rule) { rules.append(rule) }
    }

    /// The rules now.
    public var all: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    /// Whether one simple command (quotes removed) starts with a rule's words.
    func allows(_ words: [String]) -> Bool {
        // A rule read from disk is honored only while it is still eligible.
        guard let head = Self.ruleWords(words) else { return false }
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
    /// command (no pipes, lists, redirects, quotes, globs or expansion) whose rule is
    /// eligible (``isEligible(program:subcommand:)``) and, for `cmux`, with no word that asks.
    public static func prefix(for command: String) -> [String]? {
        let banned = CharacterSet(charactersIn: "|&;<>`$(){}[]\\\"'*?~=#^\n\t")
        guard command.rangeOfCharacter(from: banned) == nil else { return nil }
        return ruleWords(command.split(separator: " ", omittingEmptySubsequences: true).map(String.init))
    }

    /// The rule a simple command (quotes removed) falls under: its program and subcommand, or
    /// for a `cmux` group with one rule-eligible verb (``cmuxGroupVerbs``: `cmux chief dispatch`)
    /// the three words; nil when no rule may cover it.
    static func ruleWords(_ words: [String]) -> [String]? {
        guard words.count >= 2, isEligible(program: words[0], subcommand: words[1]) || words[0] == "cmux" else { return nil }
        guard words[0] == "cmux" else { return [words[0], words[1]] }
        if words.dropFirst().contains(where: ChiefToolPolicy.cmuxWordAsks) { return nil }
        if let verbs = cmuxGroupVerbs[words[1]] {
            return words.count >= 3 && verbs.contains(words[2]) ? Array(words.prefix(3)) : nil
        }
        return isEligible(program: words[0], subcommand: words[1]) ? [words[0], words[1]] : nil
    }

    /// `cmux` groups whose rule names the verb too, so allowing `cmux chief dispatch` never
    /// covers `cmux chief approve` or `cmux chief send`.
    static let cmuxGroupVerbs: [String: Set<String>] = ["chief": ["dispatch"]]

    /// Programs that never get a rule: shells, interpreters, wrappers that run another
    /// program, deleting programs and build or package runners.
    static let refusedPrograms: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "nu", "pwsh",
        "sudo", "su", "doas", "env", "xargs", "eval", "exec", "command", "builtin", "nohup", "time", "timeout",
        "nice", "watch", "python", "python2", "python3", "node", "deno", "bun", "ruby", "perl", "php", "lua",
        "osascript", "swift", "awk", "gawk", "sed", "find", "rm", "rmdir", "dd", "mv", "chmod", "chown", "chgrp",
        "kill", "killall", "pkill", "npx", "bunx", "pnpx", "uvx", "make", "gmake", "cmake", "ninja", "just",
    ]

    /// Subcommands that never get a rule, by program: ones that run arbitrary code or
    /// change trust settings.
    static let refusedSubcommands: [String: Set<String>] = [
        "git": ["config", "submodule", "filter-branch"],
        "npm": ["exec", "run", "run-script", "x", "start", "test"],
        "pnpm": ["exec", "run", "dlx", "x", "start", "test"],
        "yarn": ["exec", "run", "dlx", "start", "test"],
        "uv": ["run", "tool"],
        "pipx": ["run"],
        "cargo": ["run"],
        "go": ["run", "generate"],
        "docker": ["run", "exec"],
        "kubectl": ["exec", "run"],
        // `cmux` groups that run commands, type into terminals, drive a browser or answer for the user.
        "cmux": [
            "vm", "cloud", "chief", "browser", "sudo", "rpc", "ssh", "mosh", "mosh-tmux", "ssh-tmux", "hooks",
            "set-hook", "pipe-pane", "respawn-pane", "automation", "auth", "login", "logout", "ai-accounts",
            "paste", "paste-buffer", "new-workspace", "new-split", "new-pane", "new-surface", "restore-session",
            "import", "feedback", "sessions", "session", "remotes", "remote", "glaeda", "coderouter", "cr",
        ],
    ]

    /// Whether `program subcommand` may be an Always Allow rule.
    static func isEligible(program: String, subcommand sub: String) -> Bool {
        guard !refusedPrograms.contains(program), !(refusedSubcommands[program]?.contains(sub) ?? false),
              program.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil,
              sub.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { return false }
        return program != "cmux" || !ChiefToolPolicy.cmuxWordAsks(sub)
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

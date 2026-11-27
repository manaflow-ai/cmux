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
/// One exception names its target: `cmux vm exec <machine>` (``vmExecRule(_:)``) runs
/// any command on that one Cloud machine, the user's own sandbox, and never another's.
/// The brains put a card's rule in its options (``ChiefToolPolicy/approvalOptions(command:)``);
/// Home's card offers exactly that rule and never derives one itself.
public final class ChiefAllowRules: @unchecked Sendable {
    private let lock = NSLock()
    private var file: URL?
    private var rules: [[String]] = []

    public init() {}

    private struct Stored: Codable {
        var rules: [[String]]
    }

    /// Reads `home`'s rules and saves new ones there (once per home; a missing or unreadable file is
    /// no rules). A rules object may be reused by tests or a switched Chief home, so a home change
    /// replaces the in-memory snapshot instead of carrying grants across homes.
    public func load(_ home: ChiefHome) {
        let url = home.stateDirectory.appendingPathComponent("allow-rules.json", isDirectory: false)
        lock.lock()
        defer { lock.unlock() }
        guard file != url else { return }
        file = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        rules = stored?.rules.filter { (2...4).contains($0.count) && Self.ruleWords($0) == $0 } ?? []
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
        return try add(rule: words)
    }

    /// Saves an eligible rule (``ruleWords(_:)`` gives it back unchanged) and returns it; nil otherwise.
    ///
    /// - Throws: A file error when the rules cannot be written (the rule still holds for this session).
    @discardableResult
    public func add(rule words: [String]) throws -> [String]? {
        guard Self.ruleWords(words) == words else { return nil }
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

    /// The rule words for `command`: its program and subcommand, only for one simple command
    /// (no pipes, lists, file redirects, globs or `$` expansion; ``ChiefShellLexer``) whose
    /// rule is eligible (``isEligible(program:subcommand:)``), with no `--flag=value` word and,
    /// for `cmux`, no word that asks. Quotes are lexed away, so `cmux chief dispatch --name
    /// "#1: x" -- '<task>'` gets `cmux chief dispatch`.
    public static func prefix(for command: String) -> [String]? {
        guard let stages = ChiefShellLexer.stages(of: command), stages.count == 1,
              !stages[0].contains(where: \.expands) else { return nil }
        let words = stages[0].map(\.text)
        // `git diff --output=x` writes a file: no rule is offered from a flag with a value.
        guard !words.contains(where: { $0.hasPrefix("-") && $0.contains("=") }) else { return nil }
        return ruleWords(words)
    }

    /// Marks the approval option that carries a card's Always Allow rule ("always:cmux chief
    /// dispatch"). Home's card reads the rule from it and never shows it as a button
    /// (`ChiefRows.Approval` in MessagesLabHome, the same id); it is never a valid choice.
    public static let alwaysOptionPrefix = "always:"

    /// Whether `option` is the rule-carrying option (``alwaysOptionPrefix``).
    public static func isAlwaysOption(_ option: String) -> Bool { option.hasPrefix(alwaysOptionPrefix) }

    /// The rule-carrying option for the full `command` a card asks to run, nil when no rule may cover
    /// it (``prefix(for:)``). The brains derive it once from the untruncated command (the card's
    /// prompt cuts it at 300 characters), so the card and the saved rule never re-parse a prompt.
    static func alwaysOption(for command: String) -> String? {
        prefix(for: command).map { alwaysOptionPrefix + $0.joined(separator: " ") }
    }

    /// The rule a card's options carry (``alwaysOption(for:)``), nil when none or not eligible.
    public static func rule(inOptions options: [String]) -> [String]? {
        guard let option = options.first(where: isAlwaysOption) else { return nil }
        let words = option.dropFirst(alwaysOptionPrefix.count).split(separator: " ").map(String.init)
        return ruleWords(words) == words ? words : nil
    }

    /// The rule a simple command (quotes removed) falls under: its program and subcommand, or
    /// for a `cmux` group with one rule-eligible verb (``cmuxGroupVerbs``: `cmux chief dispatch`)
    /// the three words; nil when no rule may cover it.
    static func ruleWords(_ words: [String]) -> [String]? {
        if words.count >= 3, words[0] == "cmux", ["vm", "cloud"].contains(words[1]), words[2] == "exec" {
            return vmExecRule(words)
        }
        guard words.count >= 2, isEligible(program: words[0], subcommand: words[1]) || words[0] == "cmux" else { return nil }
        guard words[0] == "cmux" else { return [words[0], words[1]] }
        if words.dropFirst().contains(where: ChiefToolPolicy.cmuxWordAsks) { return nil }
        if let verbs = cmuxGroupVerbs[words[1]] {
            return words.count >= 3 && verbs.contains(words[2]) ? Array(words.prefix(3)) : nil
        }
        return isEligible(program: words[0], subcommand: words[1]) ? [words[0], words[1]] : nil
    }

    /// The rule for `cmux vm|cloud exec [--timeout <s>] [--json] <machine> [-- <command…>]`:
    /// `cmux vm exec <machine>`, the machine named, so allowing probes on one machine never
    /// covers another machine or any other `vm` verb. The remote command runs on that machine
    /// (its own sandbox) and is not checked word by word, except that it may not call `cmux`
    /// there (a machine's `cmux vm` reaches the user's other machines). Nil for any other shape.
    static func vmExecRule(_ words: [String]) -> [String]? {
        guard words.count >= 4, words[0] == "cmux", ["vm", "cloud"].contains(words[1]), words[2] == "exec" else { return nil }
        var index = 3
        while index < words.count, words[index].hasPrefix("-"), words[index] != "--" {
            switch words[index] {
            case "--timeout":
                guard index + 1 < words.count, Int(words[index + 1]) != nil else { return nil }
                index += 2
            case "--json":
                index += 1
            default:
                return nil
            }
        }
        guard index < words.count else { return nil }
        let machine = words[index]
        guard machine.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else { return nil }
        let remote = words.dropFirst(index + 1)
        guard remote.isEmpty || remote.first == "--" else { return nil }
        guard !remote.contains(where: callsCmux) else { return nil }
        return ["cmux", "vm", "exec", machine]
    }

    /// Whether a remote word runs `cmux` (`cmux …`, `/usr/local/bin/cmux …`, `x; cmux …` inside
    /// `sh -c`), not merely names its home (`HOME=/home/cmux`, `/home/cmux/work`).
    static func callsCmux(_ word: String) -> Bool {
        word.range(of: #"(^|[\s;&|(`])([^\s=;&|(`]*/)?cmux($|[\s;&|)`])"#, options: [.regularExpression, .caseInsensitive]) != nil
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

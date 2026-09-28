public import Foundation

/// One tool call an agent asked permission for, reduced to what grant rules
/// can match on.
public struct AgentPermissionRequest: Sendable, Equatable {
    public var toolName: String
    public var command: String?
    public var filePath: String?
    public var url: String?
    /// The `Glob` tool's pattern.
    public var pattern: String?
    public var cwd: String?

    public init(
        toolName: String,
        command: String? = nil,
        filePath: String? = nil,
        url: String? = nil,
        pattern: String? = nil,
        cwd: String? = nil
    ) {
        self.toolName = toolName
        self.command = command
        self.filePath = filePath
        self.url = url
        self.pattern = pattern
        self.cwd = cwd
    }

    /// Builds a request from a Claude Code `PermissionRequest` hook payload.
    public init?(claudeHookPayload payload: [String: Any]) {
        guard let toolName = payload["tool_name"] as? String, !toolName.isEmpty else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        self.init(
            toolName: toolName,
            command: input["command"] as? String,
            filePath: (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["path"] as? String),
            url: input["url"] as? String,
            pattern: input["pattern"] as? String,
            cwd: payload["cwd"] as? String
        )
    }
}


/// Decides whether a Claude-syntax permission rule allows a request.
///
/// Deliberately narrower than Claude Code's own matcher: anything it can't
/// match with certainty is not matched, so the request falls through to the
/// normal prompt.
///
/// - Shell rules match one simple command whose words use only
///   `[A-Za-z0-9_./:=@%+,-]`, optionally single-quoted with spaces inside.
///   Anything else (operators, globs, braces, `$`, `~`, backslashes, double
///   quotes, leading `VAR=value`) never matches. Prefix rules compare whole
///   words.
/// - Path rules take absolute (`//abs/...`) or home (`~/...`) roots, with an
///   optional trailing `/**`. A request path with a `..` component or a
///   symlink anywhere below the rule's root never matches, and protected
///   paths (`.git/`, `.claude/`, shell startup files, `~/.ssh`,
///   `~/Library`, cmux configuration) never match any rule.
/// - `Edit` rules cover Edit, MultiEdit, Write and NotebookEdit; `Read` rules
///   cover Read, Grep, Glob and LS. Each of those names works as the rule
///   tool, and a file rule without a path is invalid.
/// - `WebFetch(domain:d)` matches http and https URLs whose host is `d` or
///   ends in `.d`, after rejecting authorities with `\`, `@`, `%` or spaces.
public enum AgentPermissionRuleMatcher {
    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS"]
    /// Tools whose prompt needs the user's answer, never a permission.
    static let userAnswerTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// First words that run other programs or arbitrary code. Prefix rules
    /// for these are broad; so are exact rules, except exact git commands.
    private static let broadCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "env", "eval", "exec", "command", "nohup", "timeout",
        "xargs", "find", "sudo", "rm", "python", "python3", "node", "deno", "bun", "npx", "npm",
        "pnpm", "yarn", "perl", "ruby", "php", "osascript", "awk", "make", "xcrun", "ssh", "curl",
        "wget", "git",
    ]

    enum Command: Equatable {
        case any
        case prefix([String])
        case exact([String])
    }

    struct PathRule: Equatable {
        /// Lexically clean absolute path, before resolving symlinks.
        var root: String
        var recursive: Bool
    }

    enum Rule: Equatable {
        case bash(Command)
        case edit(PathRule)
        case read(PathRule)
        case webFetch(domain: String?)
        /// Any other tool, by name. `mcp__server` covers every tool of that
        /// server.
        case named(String)
    }

    /// Whether `rule` is one this matcher understands. Requests and loaded
    /// grants carrying anything else are rejected.
    public static func isValid(_ rule: String) -> Bool {
        parse(rule) != nil
    }

    public static func allows(
        rule: String,
        request: AgentPermissionRequest,
        home: String = NSHomeDirectory()
    ) -> Bool {
        guard let parsed = parse(rule, home: home) else { return false }
        switch parsed {
        case .bash(let spec):
            guard request.toolName == "Bash", let command = request.command,
                  let words = shellWords(command) else { return false }
            switch spec {
            case .any: return true
            case .prefix(let prefix): return words.starts(with: prefix)
            case .exact(let exact): return words == exact
            }
        case .edit(let pathRule):
            guard editTools.contains(request.toolName), let path = request.filePath else { return false }
            return matchesPath(pathRule, path: path, cwd: request.cwd, home: home)
        case .read(let pathRule):
            guard readTools.contains(request.toolName) else { return false }
            if request.toolName == "Glob" {
                guard let pattern = request.pattern, isRelativeGlob(pattern) else { return false }
            }
            guard let path = request.filePath ?? request.cwd else { return false }
            return matchesPath(pathRule, path: path, cwd: request.cwd, home: home)
        case .webFetch(let domain):
            guard request.toolName == "WebFetch", let url = request.url, let host = webHost(url) else { return false }
            guard let domain else { return true }
            return host == domain || host.hasSuffix("." + domain)
        case .named(let tool):
            if tool.hasPrefix("mcp__"), !tool.dropFirst(5).contains("__") {
                return request.toolName.hasPrefix(tool + "__")
            }
            return request.toolName == tool
        }
    }

    /// Whether a rule covers more than a user would expect from one
    /// approval. Broad rules start unchecked in the approval panel.
    ///
    /// - Shell: no specifier, `*`, or a first word (by basename) that is a
    ///   shell, interpreter, wrapper, or another command that runs arbitrary
    ///   code, such as `git` through `-c` config. Exact git commands are not
    ///   broad.
    /// - Paths: a root that resolves to `/`, the home directory, an ancestor
    ///   of home, or a protected path.
    /// - WebFetch: no domain, or a domain without a dot.
    /// - Invalid rules count as broad.
    public static func isBroad(_ rule: String, home: String = NSHomeDirectory()) -> Bool {
        guard let parsed = parse(rule, home: home) else { return true }
        switch parsed {
        case .bash(.any):
            return true
        case .bash(.prefix(let words)):
            return words.first.map { broadCommands.contains(basename($0)) } ?? true
        case .bash(.exact(let words)):
            guard let first = words.first.map(basename) else { return true }
            return first != "git" && broadCommands.contains(first)
        case .edit(let pathRule), .read(let pathRule):
            guard let root = AgentPermissionPath.canonical(pathRule.root),
                  let canonicalHome = AgentPermissionPath.canonical(home) else { return true }
            return root == "/" || root == canonicalHome || canonicalHome.hasPrefix(root + "/")
                || AgentPermissionPath.isProtected(pathRule.root, home: home)
        case .webFetch(let domain):
            return domain.map { !$0.contains(".") } ?? true
        case .named:
            return false
        }
    }

    static func parse(_ rule: String, home: String = NSHomeDirectory()) -> Rule? {
        guard !rule.isEmpty, rule.count <= AgentPermissionGrantProposal.maximumRuleLength,
              !AgentPermissionText.containsInvisibleOrControl(rule),
              rule == rule.trimmingCharacters(in: .whitespaces) else { return nil }
        let tool: String
        let specifier: String?
        if let open = rule.firstIndex(of: "(") {
            guard rule.hasSuffix(")") else { return nil }
            tool = String(rule[..<open])
            let inner = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
            specifier = inner.isEmpty ? nil : inner
        } else {
            tool = rule
            specifier = nil
        }
        guard isToolName(tool), !userAnswerTools.contains(tool) else { return nil }

        if tool == "Bash" {
            return bashCommand(specifier).map(Rule.bash)
        }
        if editTools.contains(tool) {
            return specifier.flatMap { pathRule($0, home: home) }.map(Rule.edit)
        }
        if readTools.contains(tool) {
            return specifier.flatMap { pathRule($0, home: home) }.map(Rule.read)
        }
        if tool == "WebFetch" {
            guard let specifier else { return .webFetch(domain: nil) }
            guard specifier.hasPrefix("domain:") else { return nil }
            let domain = String(specifier.dropFirst("domain:".count)).lowercased()
            return isHostName(domain) ? .webFetch(domain: domain) : nil
        }
        return specifier == nil ? .named(tool) : nil
    }

    // MARK: Shell

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "/", ":", "=", "@", "%", "+", ",", "-": true
        default: false
        }
    }

    /// The words of one simple command, unquoted, or `nil` when the command
    /// uses anything outside the allowlist.
    static func shellWords(_ command: String) -> [String]? {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        var inQuote = false
        for scalar in command.unicodeScalars {
            if inQuote {
                if scalar == "'" {
                    inQuote = false
                } else if scalar == " " || isWordScalar(scalar) {
                    current.append(scalar)
                } else {
                    return nil
                }
                continue
            }
            switch scalar {
            case " ":
                if inWord { words.append(String(current)) }
                current = String.UnicodeScalarView()
                inWord = false
            case "'":
                inQuote = true
                inWord = true
            default:
                guard isWordScalar(scalar) else { return nil }
                current.append(scalar)
                inWord = true
            }
        }
        guard !inQuote else { return nil }
        if inWord { words.append(String(current)) }
        // `VAR=value cmd` changes the command's environment; zsh expands a
        // word starting with `=` to a command path.
        guard let first = words.first, !first.isEmpty, !first.contains("="),
              !words.contains(where: { $0.hasPrefix("=") }) else { return nil }
        return words
    }

    private static func bashCommand(_ specifier: String?) -> Command? {
        guard let specifier, specifier != "*" else { return .any }
        for suffix in [":*", " *"] where specifier.hasSuffix(suffix) {
            return shellWords(String(specifier.dropLast(suffix.count))).map(Command.prefix)
        }
        return shellWords(specifier).map(Command.exact)
    }

    private static func basename(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    // MARK: Paths

    /// `//abs/dir/**`, `~/dir/**`, `~`, or an exact absolute or home file.
    private static func pathRule(_ specifier: String, home: String) -> PathRule? {
        var body: String
        if specifier.hasPrefix("//") {
            body = String(specifier.dropFirst())
        } else if specifier == "~" || specifier.hasPrefix("~/") {
            body = home + specifier.dropFirst()
        } else {
            return nil
        }
        var recursive = false
        if body.hasSuffix("/**") {
            body.removeLast(3)
            recursive = true
        }
        guard !body.contains("*"), !body.contains("~"),
              let components = AgentPermissionPath.components(ofAbsolute: body.isEmpty ? "/" : body),
              recursive || !components.isEmpty else { return nil }
        return PathRule(root: AgentPermissionPath.join(components), recursive: recursive)
    }

    private static func matchesPath(_ rule: PathRule, path: String, cwd: String?, home: String) -> Bool {
        guard let path = AgentPermissionPath.requestPath(path, cwd: cwd),
              !AgentPermissionPath.isProtected(path, home: home) else { return false }
        if rule.recursive {
            guard let root = AgentPermissionPath.canonical(rule.root) else { return false }
            return AgentPermissionPath.componentsBelow(root: root, path: path) != nil
        }
        let parent = (rule.root as NSString).deletingLastPathComponent
        guard let root = AgentPermissionPath.canonical(parent) else { return false }
        return AgentPermissionPath.componentsBelow(root: root, path: path) == [(rule.root as NSString).lastPathComponent]
    }

    /// A Glob pattern that stays under the search path.
    private static func isRelativeGlob(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("/") && !pattern.hasPrefix("~")
            && !pattern.split(separator: "/").contains("..")
    }

    // MARK: WebFetch

    private static func isToolName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("A"..."Z").contains(first) || ("a"..."z").contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
            default: false
            }
        }
    }

    private static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("..")
            && host.unicodeScalars.allSatisfy { scalar in
                switch scalar {
                case "a"..."z", "0"..."9", ".", "-": true
                default: false
                }
            }
    }

    /// The lowercased host of an http or https URL, or `nil` when the
    /// authority carries anything a URL parser could read differently.
    static func webHost(_ url: String) -> String? {
        guard let separator = url.range(of: "://") else { return nil }
        let scheme = url[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https",
              !url.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let rest = url[separator.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.contains(where: { $0 == "\\" || $0 == "@" || $0 == "%" }) else { return nil }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        let host = parts[0].lowercased()
        return isHostName(host) ? host : nil
    }
}

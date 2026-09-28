public import Foundation

/// One tool call an agent asked permission for, reduced to what grant rules
/// can match on.
public struct AgentPermissionRequest: Sendable, Equatable {
    public var toolName: String
    public var command: String?
    public var filePath: String?
    public var url: String?
    public var cwd: String?

    public init(toolName: String, command: String? = nil, filePath: String? = nil, url: String? = nil, cwd: String? = nil) {
        self.toolName = toolName
        self.command = command
        self.filePath = filePath
        self.url = url
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
            cwd: payload["cwd"] as? String
        )
    }
}

/// Decides whether a Claude-syntax permission rule allows a request.
///
/// Deliberately narrower than Claude Code's own matcher: anything it can't
/// match with certainty is not matched, so the request falls through to the
/// normal prompt. Shell rules only match a single simple command (no `;`,
/// `&&`, `||`, pipes, substitution, backgrounding, or redirection), and path
/// rules only take absolute (`//abs/...`) or home (`~/...`) paths.
public enum AgentPermissionRuleMatcher {
    private static let fileEditTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let fileReadTools: Set<String> = ["Read", "Grep", "Glob", "LS"]
    private static let shellControlFragments = [";", "&", "|", "`", "$(", ">", "<", "\n", "\r", "\\"]

    public static func allows(rule: String, request: AgentPermissionRequest) -> Bool {
        guard let parsed = parse(rule) else { return false }
        switch parsed.tool {
        case "Bash":
            guard request.toolName == "Bash", let command = request.command else { return false }
            guard let specifier = parsed.specifier else { return isSimpleCommand(command) }
            return matchesCommand(specifier: specifier, command: command)
        case "Edit":
            guard fileEditTools.contains(request.toolName) else { return false }
            return matchesPath(specifier: parsed.specifier, path: request.filePath, cwd: request.cwd)
        case "Read":
            guard fileReadTools.contains(request.toolName) else { return false }
            return matchesPath(specifier: parsed.specifier, path: request.filePath ?? request.cwd, cwd: request.cwd)
        case "WebFetch":
            guard request.toolName == "WebFetch" else { return false }
            guard let specifier = parsed.specifier else { return true }
            return matchesDomain(specifier: specifier, url: request.url)
        default:
            // Other tools (Grep, WebSearch, mcp__server__tool) match by name only.
            guard parsed.specifier == nil else { return false }
            if parsed.tool.hasPrefix("mcp__"), !parsed.tool.dropFirst(5).contains("__") {
                return request.toolName.hasPrefix(parsed.tool + "__")
            }
            return request.toolName == parsed.tool
        }
    }

    /// Whether a rule covers more than a user would expect from one approval:
    /// any shell command, any file, or any host. The approval UI asks twice.
    public static func isBroad(_ rule: String) -> Bool {
        guard let parsed = parse(rule) else { return true }
        switch parsed.tool {
        case "Bash":
            guard let specifier = parsed.specifier else { return true }
            let prefix = commandPrefix(specifier).trimmingCharacters(in: .whitespaces)
            return prefix.isEmpty || prefix == "*" || ["sudo", "rm", "sh", "bash", "zsh", "env", "eval"].contains(prefix.split(separator: " ").first.map(String.init) ?? "")
        case "Edit", "Read":
            guard let specifier = parsed.specifier, let root = pathRoot(specifier) else { return true }
            return root == "/" || AgentPermissionPath.canonical("~") == AgentPermissionPath.canonical(root)
        case "WebFetch":
            return parsed.specifier == nil
        default:
            return false
        }
    }

    static func parse(_ rule: String) -> (tool: String, specifier: String?)? {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        guard let open = rule.firstIndex(of: "(") else {
            return rule.isEmpty ? nil : (rule, nil)
        }
        guard rule.hasSuffix(")") else { return nil }
        let tool = String(rule[..<open])
        let specifier = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        guard !tool.isEmpty else { return nil }
        return (tool, specifier.isEmpty ? nil : specifier)
    }

    static func isSimpleCommand(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty
            && !shellControlFragments.contains { command.contains($0) }
    }

    /// `git:*` and `git *` match `git` followed by anything; otherwise exact.
    private static func matchesCommand(specifier: String, command: String) -> Bool {
        guard isSimpleCommand(command) else { return false }
        let command = command.trimmingCharacters(in: .whitespaces)
        if specifier.hasSuffix(":*") || specifier.hasSuffix(" *") {
            let prefix = commandPrefix(specifier)
            guard !prefix.isEmpty else { return false }
            return command == prefix || command.hasPrefix(prefix + " ")
        }
        guard !specifier.contains("*") else { return false }
        return command == specifier
    }

    private static func commandPrefix(_ specifier: String) -> String {
        if specifier.hasSuffix(":*") || specifier.hasSuffix(" *") {
            return String(specifier.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return specifier
    }

    /// Absolute root of a path rule (`//abs/dir/**`, `~/dir/**`, or an exact file).
    private static func pathRoot(_ specifier: String) -> String? {
        var path = specifier
        if path.hasPrefix("//") {
            path.removeFirst()
        } else if !path.hasPrefix("~/") && path != "~" {
            return nil
        }
        if path.hasSuffix("/**") {
            path.removeLast(3)
        }
        guard !path.contains("*") else { return nil }
        return path.isEmpty ? "/" : path
    }

    private static func matchesPath(specifier: String?, path: String?, cwd: String?) -> Bool {
        guard let specifier else { return false }
        guard let root = pathRoot(specifier), var path else { return false }
        if !path.hasPrefix("/") && !path.hasPrefix("~") {
            guard let cwd else { return false }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        if specifier.hasSuffix("/**") {
            return AgentPermissionPath.isSameOrDescendant(path, of: root)
        }
        return AgentPermissionPath.canonical(path) == AgentPermissionPath.canonical(root)
    }

    private static func matchesDomain(specifier: String, url: String?) -> Bool {
        guard specifier.hasPrefix("domain:"),
              let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
        let domain = specifier.dropFirst("domain:".count).lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

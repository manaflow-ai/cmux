import Foundation

/// Derives the outer launcher that started an agent from its parent's argv.
///
/// A launcher such as `sr claude proxy --account x --resume ID 'hi'` runs
/// `claude ... --resume ID 'hi'`: the agent's argv ends with the arguments the
/// launcher forwarded. Stripping that shared suffix from the parent's argv
/// leaves the launcher itself (`sr claude proxy --account x`), which recovery
/// can call with fresh resume arguments. Shells and terminal multiplexers
/// are not launchers, and a prefix that never names the agent kind is
/// rejected so an unrelated parent cannot hijack resume.
public struct AgentLauncherPrefix: Equatable, Sendable {
    private static let nonLauncherNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "dash", "nu", "login",
        "tmux", "screen", "zellij", "script", "sudo", "su", "env", "launchd",
        "cmux", "cmux-claude-wrapper",
    ]

    /// The agent kind (`claude`, `codex`).
    public let kind: String

    public init(kind: String) {
        self.kind = kind
    }

    /// - Parameters:
    ///   - agentArguments: The agent process argv, including `argv[0]`.
    ///   - parentArguments: The parent process argv, including `argv[0]`.
    /// - Returns: The launcher argv, or nil when the parent is not a launcher.
    public func derive(agentArguments: [String], parentArguments: [String]) -> [String]? {
        guard let parentExecutable = parentArguments.first,
              !Self.nonLauncherNames.contains(Self.executableName(parentExecutable)),
              Self.executableName(parentExecutable) != kind else {
            return nil
        }
        let agentTail = Array(agentArguments.dropFirst())
        var shared = 0
        while shared < agentTail.count,
              shared < parentArguments.count - 1,
              parentArguments[parentArguments.count - 1 - shared] == agentTail[agentTail.count - 1 - shared] {
            shared += 1
        }
        let prefix = Array(parentArguments.dropLast(shared))
        // A token the agent also received means the launcher reordered or
        // extended what it forwarded, so the suffix match could not separate
        // the launcher from the old session's input (a prompt, a resume id).
        let unforwarded = Set(agentTail.dropLast(shared))
        guard !prefix.isEmpty,
              prefix.contains(where: { Self.executableName($0) == kind }),
              !prefix.dropFirst().contains(where: unforwarded.contains),
              Self.isReplayable(prefix) else {
            return nil
        }
        return prefix
    }

    /// Whether a recorded launcher argv may be run again ahead of fresh
    /// resume arguments: it must not carry a credential or select a session
    /// itself (`--resume OLD`, `--continue`), which would replay the old
    /// session's input or fight the new resume id.
    public static func isReplayable(_ prefix: [String]) -> Bool {
        !prefix.isEmpty
            && !prefix.contains(where: looksSecret)
            && !prefix.dropFirst().contains(where: selectsSession)
    }

    private static let sessionSelectingOptions: Set<String> = [
        "--resume", "-r", "--continue", "-c", "--session-id", "--fork-session",
    ]

    private static func selectsSession(_ token: String) -> Bool {
        let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        return sessionSelectingOptions.contains(flag)
    }

    /// The prefix is persisted to disk, so a launcher argv that seems to
    /// carry a credential is not recorded at all.
    private static func looksSecret(_ token: String) -> Bool {
        let lowered = token.lowercased()
        let flag = lowered.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lowered
        if flag == "--key" || flag == "-k" { return true }
        if lowered.hasPrefix("sk-") { return true }
        return ["token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "bearer"]
            .contains { lowered.contains($0) }
    }

    private static func executableName(_ value: String) -> String {
        var name = URL(fileURLWithPath: value).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }
}

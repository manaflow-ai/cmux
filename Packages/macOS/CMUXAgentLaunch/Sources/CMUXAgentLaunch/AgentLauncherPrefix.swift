public import Foundation

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
        guard !prefix.isEmpty,
              prefix.contains(where: { Self.executableName($0) == kind }) else {
            return nil
        }
        return prefix
    }

    private static func executableName(_ value: String) -> String {
        var name = URL(fileURLWithPath: value).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }
}

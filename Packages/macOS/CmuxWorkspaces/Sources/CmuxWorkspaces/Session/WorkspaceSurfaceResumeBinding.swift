public import Foundation

/// Protocol seam for the app target's surface resume snapshot DTO.
///
/// `CmuxSession` owns the restore policy while the app target continues to own
/// the concrete Codable payload that preserves the persisted wire format.
public protocol WorkspaceSurfaceResumeBinding: Sendable {
    /// The binding source, for example `agent-hook` or `process-detected`.
    var source: String? { get }
    /// The binding kind, for example `hermes-agent`.
    var kind: String? { get }
    /// The shell command restored for this binding.
    var command: String { get set }
    /// The working directory associated with the restored command.
    var cwd: String? { get }
    /// Environment values restored with the command.
    var environment: [String: String]? { get set }
    /// Whether this binding came from a process detector.
    var isProcessDetected: Bool { get }
    /// Whether this binding came from a managed agent hook.
    var isAgentHookBinding: Bool { get }
    /// Whether this binding permits automatic resume without prompting.
    var allowsAutomaticResume: Bool { get }
    /// Whether this binding's approval policy requires prompting.
    var requiresPromptApproval: Bool { get }
    /// Whether this binding is explicitly configured for automatic resume.
    var autoResume: Bool? { get }

    /// Returns the startup input used to replay this binding in an interactive shell.
    func startupInputWithLauncherScript(
        fileManager: FileManager,
        temporaryDirectory: URL,
        allowLauncherScript: Bool
    ) -> String?

    /// Returns a launcher command used when the restored terminal should run a command.
    ///
    /// `returnWorkingDirectory` is the resolved session directory the OUTER login shell should
    /// return to after the resumed command exits, used as a fallback when the binding carries no
    /// `cwd` of its own so the post-exit shell never lands at the surface default (`$HOME` / `/`).
    /// See https://github.com/manaflow-ai/cmux/issues/7031.
    func startupCommandWithLauncherScript(
        fileManager: FileManager,
        temporaryDirectory: URL,
        returnWorkingDirectory: String?
    ) -> String?
}

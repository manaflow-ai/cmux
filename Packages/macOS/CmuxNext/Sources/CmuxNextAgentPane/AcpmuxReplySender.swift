public import Foundation

/// Sends a person's message to an acpmux session (`acpmux send <session> <text> --no-wait
/// --no-steer`: a Feed report's reply wakes its poster), off the main thread: the process start
/// (fork and exec) and the wait for its exit run on this actor, and the caller is a view's action
/// (plans/cmux-next/main-thread-budget.md). Only the result goes back to the main actor.
///
/// ```swift
/// let sender = AcpmuxReplySender()
/// let sent = await sender.send(session: report.sender, text: reply, environment: feed.acpmuxEnvironment)
/// ```
public actor AcpmuxReplySender {
    private let launcher: any ProcessLaunching
    private let baseEnvironment: [String: String]

    /// - Parameters:
    ///   - launcher: Runs the process (tests pass a fake that records where it ran).
    ///   - baseEnvironment: The environment the child starts from, under acpmux's own variables
    ///     (the app's; tests pass their own).
    public init(launcher: any ProcessLaunching = ProcessLauncher(),
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.launcher = launcher
        self.baseEnvironment = baseEnvironment
    }

    /// Sends `text` and waits for acpmux's answer (bounded by the launcher's deadline).
    ///
    /// - Parameters:
    ///   - session: The acpmux session that gets the message.
    ///   - text: The message.
    ///   - environment: The acpmux this app runs, resolved once at startup (nil: none).
    /// - Returns: Whether acpmux took the message (exit status 0). False for an empty session, no
    ///   acpmux, a process that did not start, a refusal (a session that ended, a peer check that
    ///   failed) or a send past its deadline.
    public func send(session: String, text: String, environment: AcpmuxEnvironment?) async -> Bool {
        guard !session.isEmpty, let environment else { return false }
        let variables = baseEnvironment.merging(environment.childEnvironment) { _, value in value }
        let status = await launcher.run(environment.executable, arguments: ["send", session, text, "--no-wait", "--no-steer"],
                                        environment: variables)
        return status == 0
    }
}

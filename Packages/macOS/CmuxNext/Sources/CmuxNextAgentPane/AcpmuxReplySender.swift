public import Foundation

/// Sends a person's message to an acpmux session (`acpmux send <session> <text> --no-wait
/// --no-steer`: a Feed report's reply wakes its poster), off the main thread: launching a process
/// blocks the caller for the fork and exec, and the caller is a view's action
/// (plans/cmux-next/main-thread-budget.md). Only the result goes back to the main actor.
///
/// ```swift
/// let sender = AcpmuxReplySender()
/// let started = await sender.send(session: report.sender, text: reply, environment: environment)
/// ```
public actor AcpmuxReplySender {
    private let launcher: any ProcessLaunching

    /// - Parameter launcher: Starts the process (tests pass a fake that records where it ran).
    public init(launcher: any ProcessLaunching = ProcessLauncher()) {
        self.launcher = launcher
    }

    /// Starts the send; it does not wait for acpmux.
    ///
    /// - Parameters:
    ///   - session: The acpmux session that gets the message.
    ///   - text: The message.
    ///   - environment: The acpmux this app runs.
    /// - Returns: Whether the process started (false for an empty session).
    public func send(session: String, text: String, environment: AcpmuxEnvironment) -> Bool {
        guard !session.isEmpty else { return false }
        let variables = ProcessInfo.processInfo.environment.merging(environment.childEnvironment) { _, value in value }
        return launcher.launch(environment.executable, arguments: ["send", session, text, "--no-wait", "--no-steer"],
                               environment: variables)
    }
}

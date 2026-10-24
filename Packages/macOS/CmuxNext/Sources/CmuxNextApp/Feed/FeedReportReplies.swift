import CmuxNextAgentPane
import Foundation

/// Sends a person's reply to a report's poster (`acpmux send <session> <text> --no-wait
/// --no-steer`), off the main thread: launching a process blocks the caller for the fork and exec,
/// and the caller is the Feed page's view (plans/cmux-next/main-thread-budget.md). Only the
/// result goes back to the main actor.
actor FeedReportReplies {
    private let launcher: any ProcessLaunching

    /// - Parameter launcher: Starts the process (tests pass a fake that records where it ran).
    init(launcher: any ProcessLaunching = ProcessLauncher()) {
        self.launcher = launcher
    }

    /// Starts the send and returns whether the process started (it does not wait for acpmux).
    func send(session: String, text: String, environment: AcpmuxEnvironment) -> Bool {
        guard !session.isEmpty else { return false }
        let variables = ProcessInfo.processInfo.environment.merging(environment.childEnvironment) { _, value in value }
        return launcher.launch(environment.executable, arguments: ["send", session, text, "--no-wait", "--no-steer"],
                               environment: variables)
    }
}

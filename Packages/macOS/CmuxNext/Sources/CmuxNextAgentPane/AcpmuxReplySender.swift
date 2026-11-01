public import Foundation

/// Sends a person's message to an acpmux session (`acpmux send --no-wait --no-steer --prompt-id
/// <id> -- <session> -`, the text on stdin: a Feed report's reply wakes its poster), off the main thread: the process start
/// (fork and exec) and the wait for its exit run on this actor, and the caller is a view's action
/// (plans/cmux-next/main-thread-budget.md). Only the result goes back to the main actor.
///
/// ```swift
/// let sender = AcpmuxReplySender()
/// let sent = await sender.send(session: report.sender, text: reply, promptID: id, environment: feed.acpmuxEnvironment)
/// ```
///
/// The text never is an argument: acpmux reads a prompt from stdin when its text words are empty or
/// exactly `-` (`arg_or_stdin`, even after `--`), so a reply of `-`, `--` or nothing would change
/// how acpmux reads its input. The arguments end in `-` and the reply goes through stdin, byte for
/// byte (acpmux trims trailing whitespace from a prompt read there). The flags come first and `--`
/// ends them. The prompt id is the caller's: a reply that is sent
/// again with the same id (its first send passed its deadline after acpmux may have queued it) is
/// delivered once, because acpmux's outbox answers a repeated id with its first delivery.
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
    ///   - promptID: The message's id, minted by the caller once per message and kept while the
    ///     same message is sent again, so a retry never delivers it twice.
    ///   - environment: The acpmux this app runs, resolved once at startup (nil: none).
    /// - Returns: Whether acpmux took the message (exit status 0). False for an empty session or
    ///   prompt id, no acpmux, a process that did not start, a refusal (a session that ended, a
    ///   peer check that failed) or a send past its deadline.
    public func send(session: String, text: String, promptID: String, environment: AcpmuxEnvironment?) async -> Bool {
        guard !session.isEmpty, !promptID.isEmpty, let environment else { return false }
        let variables = baseEnvironment.merging(environment.childEnvironment) { _, value in value }
        let status = await launcher.run(environment.executable, arguments: Self.arguments(session: session, promptID: promptID),
                                        environment: variables, input: Data(text.utf8))
        return status == 0
    }

    /// `acpmux send`'s arguments: every flag before `--`, then the session and `-` (the text comes on stdin).
    nonisolated static func arguments(session: String, promptID: String) -> [String] {
        ["send", "--no-wait", "--no-steer", "--prompt-id", promptID, "--", session, "-"]
    }
}

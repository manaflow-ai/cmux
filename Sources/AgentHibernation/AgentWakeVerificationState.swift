import Foundation

/// Pure state for checking that an agent woken from hibernation came back.
///
/// The owner feeds it the signals it sees for one pane: the wake itself, an
/// agent hook reporting for the pane, the resume command returning to the
/// shell prompt, and the verification deadline.
enum AgentWakeVerificationState: Equatable, Sendable {
    case pending
    case succeeded
    case failed(AgentWakeFailureReason)

    enum Event: Equatable, Sendable {
        /// A wake (or a retry) typed the resume command into the pane.
        case started
        /// An agent hook reported a PID or a lifecycle state for the pane.
        case agentReported
        /// A live process of the woken agent was found in the pane, which
        /// confirms agents without hooks.
        case liveProcessFound
        /// The resume command ended and the shell prompt came back.
        case commandEnded
        /// The verification deadline passed. `hasLiveProcess` says whether a
        /// live agent process was found for the pane at that moment.
        case deadline(hasLiveProcess: Bool)
    }

    func applying(_ event: Event) -> AgentWakeVerificationState {
        switch (self, event) {
        case (_, .started):
            return .pending
        case (_, .agentReported):
            // A report after a failure means the agent did come back.
            return .succeeded
        case (.pending, .liveProcessFound):
            return .succeeded
        case (.pending, .commandEnded):
            return .failed(.exitedBeforeStart)
        case (.pending, .deadline(let hasLiveProcess)):
            // Some agents have no hooks; a live process is enough.
            return hasLiveProcess ? .succeeded : .failed(.didNotStart)
        case (.succeeded, _), (.failed, _):
            return self
        }
    }

    var failureReason: AgentWakeFailureReason? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

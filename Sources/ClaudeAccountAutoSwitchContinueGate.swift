import CmuxAgentJournal
import Foundation

/// Decides when an automatic account switch may type `continue` into the resumed Claude.
///
/// Spec D8: cmux types only into Claude's empty input prompt, never into a trust prompt, a
/// dialog or a draft. A shell prompt such as `❯ ` reads as an empty prompt on screen, so the
/// screen counts only after Claude's own `SessionStart` hook reported the resumed session in the
/// pane. A turn, a permission or question request, or the session ending means someone else
/// is driving the pane, and the wait ends without typing.
struct ClaudeAccountAutoSwitchContinueGate: Equatable, Sendable {
    /// How long the gate waits for the empty prompt before giving up.
    static let timeout: Duration = .seconds(60)
    /// How often the coordinator reads the screen while waiting.
    static let pollInterval: Duration = .milliseconds(500)

    /// What to do on one poll.
    enum Step: Equatable, Sendable {
        case wait
        case send
        case giveUp(GiveUpReason)
    }

    /// Why the gate stopped without typing.
    enum GiveUpReason: String, Equatable, Sendable {
        case timedOut
        case sessionEnded
        case sessionBusy
        case disabled
        case paneGone
    }

    /// Whether the resumed Claude reported its session start in the pane.
    private(set) var claudeStarted = false
    /// Set by an event that ends the wait.
    private(set) var interruption: GiveUpReason?

    /// Folds in one journal event from the pane's top-level Claude.
    mutating func observe(kind: AgentJournalEventKind) {
        switch kind {
        case .sessionStarted:
            claudeStarted = true
        case .sessionEnded:
            // Before the resumed session starts, this is the replaced Claude exiting.
            if claudeStarted, interruption == nil { interruption = .sessionEnded }
        case .turnStarted, .approvalRequested, .questionRequested, .planReviewRequested:
            if interruption == nil { interruption = .sessionBusy }
        case .errorReported, .turnCompleted, .childSpawned, .childCompleted, .childFailed, .stateChanged,
             .idleObserved, .attentionResolved, .messagePublished:
            // The usage-limit report's own attention echo lands here too; it says nothing about
            // the resumed session.
            break
        }
    }

    /// The step for one poll.
    ///
    /// - Parameters:
    ///   - elapsed: Time since the switch typed the resume command.
    ///   - isEnabled: Whether `automation.claudeAccountAutoSwitch` is still on.
    ///   - responseRunning: Whether the pane's Claude is mid-turn.
    ///   - screen: Reads the pane's screen; called only when everything else allows typing.
    func step(
        elapsed: Duration,
        isEnabled: Bool,
        responseRunning: Bool,
        screen: () -> AgentAutoResumeCoordinator.ScreenState
    ) -> Step {
        if let interruption { return .giveUp(interruption) }
        guard isEnabled else { return .giveUp(.disabled) }
        guard elapsed < Self.timeout else { return .giveUp(.timedOut) }
        guard claudeStarted else { return .wait }
        guard !responseRunning else { return .giveUp(.sessionBusy) }
        return screen() == .emptyPrompt ? .send : .wait
    }
}

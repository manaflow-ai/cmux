import CMUXMobileCore
import CmuxAgentJournal
import Foundation

/// Decides when an automatic account switch may type `continue` into the resumed Claude.
///
/// Spec D8: cmux types only into the resumed Claude's idle input prompt, never into a trust
/// prompt, a dialog, a draft, a running turn or a shell. A shell prompt such as `❯ ` reads as an
/// empty prompt on screen, so the screen counts only after the resumed session's own
/// `SessionStart` (``sessionId``) reached the pane, and only while the Claude registered for the
/// pane after the switch owns the terminal's foreground. Anything that shows someone else
/// driving the pane ends the wait: input, a turn, a permission or question request, another
/// session starting, or the resumed session ending.
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
        case otherSession
        case userInput
        case disabled
        case paneGone
    }

    /// What the pane's screen shows.
    struct Screen: Equatable, Sendable {
        /// The shared prompt classification.
        let state: AgentAutoResumeCoordinator.ScreenState
        /// Whether Claude's running-turn hint (`esc to interrupt`) is on screen. Claude keeps its
        /// input box empty while it works, so the classification alone reads a running turn as
        /// an empty prompt.
        let showsInterruptHint: Bool

        init(state: AgentAutoResumeCoordinator.ScreenState, showsInterruptHint: Bool) {
            self.state = state
            self.showsInterruptHint = showsInterruptHint
        }

        /// Reads `frame`.
        @MainActor
        init(frame: MobileTerminalRenderGridFrame) {
            self.init(
                state: AgentAutoResumeCoordinator.screenState(in: frame),
                showsInterruptHint: Self.showsInterruptHint(in: frame)
            )
        }

        /// Whether any row of `frame` reads `esc to interrupt`, ignoring case.
        static func showsInterruptHint(in frame: MobileTerminalRenderGridFrame) -> Bool {
            var rows: [Int: [(column: Int, text: String)]] = [:]
            for span in frame.rowSpans {
                rows[span.row, default: []].append((span.column, span.text))
            }
            return rows.values.contains { spans in
                let line = spans.sorted { $0.column < $1.column }.reduce(into: "") { result, span in
                    let padding = span.column - result.count
                    if padding > 0 { result += String(repeating: " ", count: padding) }
                    result += span.text
                }
                return line.lowercased().contains("esc to interrupt")
            }
        }
    }

    /// The conversation the switch resumed; only its `SessionStart` opens the gate.
    let sessionId: String
    /// Whether the resumed session reported its start in the pane.
    private(set) var claudeStarted = false
    /// Set by an event that ends the wait.
    private(set) var interruption: GiveUpReason?
    /// Polls in a row that found the resumed session started and its Claude registered in the
    /// terminal's foreground.
    private var settledPolls = 0
    /// Whether the switch notification was handed out.
    private(set) var announced = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    /// Folds in one journal event from the pane's top-level Claude.
    mutating func observe(kind: AgentJournalEventKind, sessionId: String?) {
        switch kind {
        case .sessionStarted:
            // Only the resumed conversation counts; a `claude` started by hand or a `/clear` is
            // another session, and cmux must not type into it.
            if sessionId == self.sessionId {
                claudeStarted = true
            } else {
                interrupt(.otherSession)
            }
        case .sessionEnded:
            // Before the resumed session starts, this is the replaced Claude exiting.
            if claudeStarted { interrupt(.sessionEnded) }
        case .turnStarted, .approvalRequested, .questionRequested, .planReviewRequested:
            interrupt(.sessionBusy)
        case .errorReported, .turnCompleted, .childSpawned, .childCompleted, .childFailed, .stateChanged,
             .idleObserved, .attentionResolved, .messagePublished:
            // The usage-limit report's own attention echo lands here too; it says nothing about
            // the resumed session.
            break
        }
    }

    /// Input reached the pane: whatever cmux typed next would land in it. Called synchronously
    /// from the pane's input path, so no poll can send after it.
    mutating func userDidInput() {
        interrupt(.userInput)
    }

    /// What one poll decided: the step, and whether to post the switch notification now.
    struct Poll: Equatable, Sendable {
        let step: Step
        /// Post the "Claude account switched" notification on this poll. True at most once per
        /// gate; on a give-up the notification goes out together with the reason.
        let announce: Bool
    }

    /// One poll of the wait.
    ///
    /// The resumed Claude's `SessionStart` hook clears every notification on the pane right after
    /// it registers Claude's process, through an asynchronous queue that reports no completion.
    /// So the switch notification, and `continue` after it, wait until the resumed session
    /// started and its Claude stayed registered in the foreground for a whole poll interval,
    /// which orders them after that clear. A wait that ends without that announces the switch
    /// together with why `continue` was not typed.
    ///
    /// - Parameters:
    ///   - elapsed: Time since the switch typed the resume command.
    ///   - isEnabled: Whether `automation.claudeAccountAutoSwitch` is still on.
    ///   - responseRunning: Whether the pane's Claude is mid-turn.
    ///   - screen: Reads the pane's screen; called only when everything else allows typing.
    ///   - claudeInForeground: Whether the Claude registered for the pane after the switch is
    ///     alive and owns the terminal's foreground; called once the resumed session started.
    mutating func poll(
        elapsed: Duration,
        isEnabled: Bool,
        responseRunning: Bool,
        screen: () -> Screen,
        claudeInForeground: () -> Bool
    ) -> Poll {
        let step = nextStep(
            elapsed: elapsed,
            isEnabled: isEnabled,
            responseRunning: responseRunning,
            screen: screen,
            claudeInForeground: claudeInForeground
        )
        // A wait that ends carries the announcement if it is still owed; a settled wait owes it now.
        let due = step != .wait || settledPolls >= Self.settledPollsBeforeTyping
        return Poll(step: step, announce: due && announceIfOwed())
    }

    /// Hands out the switch notification if it is still owed, for a wait the coordinator ends
    /// itself (the pane went away, or a newer report replaced the wait).
    mutating func announceIfOwed() -> Bool {
        guard !announced else { return false }
        announced = true
        return true
    }

    /// Polls in a row the resumed Claude must be found registered in the foreground before the
    /// switch is announced and `continue` typed: one whole poll interval past its registration,
    /// after which its `SessionStart` hook's notification clear has been applied.
    private static let settledPollsBeforeTyping = 2

    private mutating func nextStep(
        elapsed: Duration,
        isEnabled: Bool,
        responseRunning: Bool,
        screen: () -> Screen,
        claudeInForeground: () -> Bool
    ) -> Step {
        if let interruption { return .giveUp(interruption) }
        guard isEnabled else { return .giveUp(.disabled) }
        guard elapsed < Self.timeout else { return .giveUp(.timedOut) }
        guard claudeStarted else { return .wait }
        guard !responseRunning else { return .giveUp(.sessionBusy) }
        // Read every poll once the session started: the announcement needs it too. A Claude not
        // yet registered may still be starting.
        settledPolls = claudeInForeground() ? settledPolls + 1 : 0
        guard settledPolls >= Self.settledPollsBeforeTyping else { return .wait }
        let reading = screen()
        guard reading.state == .emptyPrompt, !reading.showsInterruptHint else { return .wait }
        return .send
    }

    private mutating func interrupt(_ reason: GiveUpReason) {
        if interruption == nil { interruption = reason }
    }
}

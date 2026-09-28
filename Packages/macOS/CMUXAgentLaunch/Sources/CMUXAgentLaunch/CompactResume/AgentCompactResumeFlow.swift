/// The compact-and-resume sequence for one agent pane, as a state machine
/// with no I/O.
///
/// A driver feeds it what happens in the pane and performs the steps it
/// returns:
///
/// 1. If the agent is running and the timing is ``AgentCompactResumeTiming/now``,
///    interrupt the turn once, then let the agent settle.
/// 2. Once the agent is idle and its input line is empty, type the compact
///    command.
/// 3. When the agent reports compaction finished, and its input is still
///    empty, type the resume prompt.
///
/// The flow never types while the agent waits on a dialog or while its input
/// may hold a draft, and every stop after the start is quiet: it only
/// returns ``Step/finish(_:)``. Auto-compactions that finish before the flow
/// has sent its own command are ignored.
///
/// ```swift
/// var flow = AgentCompactResumeFlow(timing: .now, compactCommand: "/compact …", resumePrompt: "Continue …")
/// flow.start(lifecycle: .running) { .empty }       // [.interrupt]
/// flow.lifecycleChanged(to: .idle) { .empty }       // [.settle]
/// flow.settled(lifecycle: .idle) { .empty }         // [.send("/compact …")]
/// flow.compactionFinished(lifecycle: .idle) { .empty } // [.send("Continue …"), .finish(.resumed)]
/// ```
public struct AgentCompactResumeFlow: Sendable, Equatable {
    /// Where the run is.
    public enum Phase: Sendable, Equatable {
        /// Waiting for the agent to reach its prompt.
        case waitingForIdle
        /// The turn was interrupted; waiting a moment for the agent's UI to
        /// return to its prompt before reading the input line.
        case settling
        /// The compact command was sent; waiting for compaction to finish.
        case compacting
        /// The run ended.
        case finished(AgentCompactResumeOutcome)
    }

    /// Something the driver must do.
    public enum Step: Sendable, Equatable {
        /// Send the agent's interrupt key.
        case interrupt
        /// Wait ``AgentCompactResumeFlow/settleInterval``, then call
        /// ``AgentCompactResumeFlow/settled(lifecycle:input:)``.
        case settle
        /// Type the text into the agent's input and submit it.
        case send(String)
        /// The run is over; release its observers and timers.
        case finish(AgentCompactResumeOutcome)
    }

    /// How long to let the agent's UI settle after an interrupt.
    public static let settleInterval: Duration = .milliseconds(600)
    /// How long a run that interrupted the turn waits for the agent to go idle.
    public static let interruptedTurnTimeout: Duration = .seconds(30)
    /// How long a run that waits for the turn to end on its own may wait.
    public static let naturalTurnTimeout: Duration = .seconds(30 * 60)
    /// How long compaction may take before the run gives up.
    public static let compactionTimeout: Duration = .seconds(5 * 60)

    /// Whether the run may interrupt a running turn.
    public let timing: AgentCompactResumeTiming
    /// The command that compacts the context.
    public let compactCommand: String
    /// The prompt sent after compaction.
    public let resumePrompt: String
    /// Where the run is.
    public private(set) var phase: Phase = .waitingForIdle
    private var hasInterrupted = false

    /// Creates a flow in ``Phase/waitingForIdle``.
    ///
    /// - Parameters:
    ///   - timing: Whether the run may interrupt a running turn.
    ///   - compactCommand: The command that compacts the context.
    ///   - resumePrompt: The prompt sent after compaction.
    public init(timing: AgentCompactResumeTiming, compactCommand: String, resumePrompt: String) {
        self.timing = timing
        self.compactCommand = compactCommand
        self.resumePrompt = resumePrompt
    }

    /// How long the current phase may last before the driver calls
    /// ``timedOut()``, or `nil` when the phase has no deadline of its own.
    public var phaseTimeout: Duration? {
        switch phase {
        case .waitingForIdle:
            hasInterrupted ? Self.interruptedTurnTimeout : Self.naturalTurnTimeout
        case .compacting:
            Self.compactionTimeout
        case .settling, .finished:
            nil
        }
    }

    /// Whether the run has ended.
    public var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Starts the run from the pane's current state.
    ///
    /// Unlike later events, a start on a blocked or missing agent stops at
    /// once, so the caller can report it.
    ///
    /// - Parameters:
    ///   - lifecycle: The agent's state now.
    ///   - input: Reads the agent's input line; called only when the agent
    ///     is idle.
    /// - Returns: The steps to perform, in order.
    public mutating func start(
        lifecycle: AgentCompactResumeLifecycle,
        input: () -> AgentPromptInputState
    ) -> [Step] {
        guard phase == .waitingForIdle, !hasInterrupted else { return [] }
        switch lifecycle {
        case .absent:
            return finish(.stopped(.noAgent))
        case .blocked:
            return finish(.stopped(.blocked))
        case .running:
            guard timing == .now else { return [] }
            hasInterrupted = true
            return [.interrupt]
        case .idle:
            return compactIfInputIsEmpty(input())
        }
    }

    /// Applies a change in the agent's state.
    ///
    /// - Parameters:
    ///   - lifecycle: The agent's new state.
    ///   - input: Reads the agent's input line; called only when needed.
    /// - Returns: The steps to perform, in order.
    public mutating func lifecycleChanged(
        to lifecycle: AgentCompactResumeLifecycle,
        input: () -> AgentPromptInputState
    ) -> [Step] {
        switch phase {
        case .finished:
            return []
        case .settling, .compacting:
            return lifecycle == .absent ? finish(.stopped(.agentExited)) : []
        case .waitingForIdle:
            switch lifecycle {
            case .absent:
                return finish(.stopped(.agentExited))
            case .running, .blocked:
                // Never a second interrupt: at Claude Code's idle prompt a
                // second Escape opens its rewind menu.
                return []
            case .idle:
                guard hasInterrupted else { return compactIfInputIsEmpty(input()) }
                phase = .settling
                return [.settle]
            }
        }
    }

    /// Continues after the settle wait that followed an interrupt.
    ///
    /// - Parameters:
    ///   - lifecycle: The agent's state now.
    ///   - input: Reads the agent's input line; called only when idle.
    /// - Returns: The steps to perform, in order.
    public mutating func settled(
        lifecycle: AgentCompactResumeLifecycle,
        input: () -> AgentPromptInputState
    ) -> [Step] {
        guard phase == .settling else { return [] }
        phase = .waitingForIdle
        switch lifecycle {
        case .idle:
            return compactIfInputIsEmpty(input())
        case .absent:
            return finish(.stopped(.agentExited))
        case .running, .blocked:
            // The agent picked up work again; wait for the next idle.
            return []
        }
    }

    /// Applies the agent's report that a compaction finished.
    ///
    /// - Parameters:
    ///   - lifecycle: The agent's state now.
    ///   - input: Reads the agent's input line.
    /// - Returns: The steps to perform, in order.
    public mutating func compactionFinished(
        lifecycle: AgentCompactResumeLifecycle,
        input: () -> AgentPromptInputState
    ) -> [Step] {
        // A compaction before ours (the agent's own auto-compaction) is not
        // the one this run asked for.
        guard phase == .compacting else { return [] }
        switch lifecycle {
        case .absent:
            return finish(.stopped(.agentExited))
        case .blocked:
            return finish(.stopped(.blocked))
        case .running, .idle:
            switch input() {
            case .empty:
                return [.send(resumePrompt)] + finish(.resumed)
            case .hasText:
                return finish(.stopped(.inputNotEmpty))
            case .unknown:
                return finish(.stopped(.inputUnreadable))
            }
        }
    }

    /// Gives up on the current phase.
    ///
    /// - Returns: A finishing step, or nothing when the run already ended.
    public mutating func timedOut() -> [Step] {
        isFinished ? [] : finish(.stopped(.timedOut))
    }

    private mutating func compactIfInputIsEmpty(_ input: AgentPromptInputState) -> [Step] {
        switch input {
        case .empty:
            phase = .compacting
            return [.send(compactCommand)]
        case .hasText:
            return finish(.stopped(.inputNotEmpty))
        case .unknown:
            return finish(.stopped(.inputUnreadable))
        }
    }

    private mutating func finish(_ outcome: AgentCompactResumeOutcome) -> [Step] {
        phase = .finished(outcome)
        return [.finish(outcome)]
    }
}

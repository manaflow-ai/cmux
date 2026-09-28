import CMUXAgentLaunch
import Foundation

/// Drives one compact-and-resume run on a terminal pane: feeds the pure
/// ``AgentCompactResumeFlow`` the pane's lifecycle changes, the agent's
/// PostCompact reports and its deadlines, and performs the steps it returns
/// through the pane.
///
/// The pane owns the run while it is active and drops it when the run
/// finishes. Everything typed goes through the pane's explicit-input path.
@MainActor
final class AgentCompactResumeRun {
    /// What the run needs from its pane.
    struct Pane {
        /// The agent's lifecycle on the pane now.
        var lifecycle: @MainActor () -> AgentCompactResumeLifecycle
        /// Reads the agent's input line. Only called when the flow needs it.
        var readInput: @MainActor () -> AgentPromptInputState
        /// Interrupts the running turn (the Stop button's path).
        var interrupt: @MainActor () -> Void
        /// Types a line into the agent and submits it.
        var submit: @MainActor (String) -> Void
    }

    let agent: AgentTurnInterruptTarget
    let surfaceID: UUID
    let sessionID: String?
    private(set) var flow: AgentCompactResumeFlow
    private let pane: Pane
    private let settleInterval: Duration
    private let onPhaseChange: @MainActor (AgentCompactResumeFlow.Phase) -> Void
    private var compactionObserver: NSObjectProtocol?
    private var deadline: Task<Void, Never>?
    private var deadlinePhase: AgentCompactResumeFlow.Phase?
    private var settleWait: Task<Void, Never>?
    /// The last phase handed to `onPhaseChange`. Compared after each step
    /// batch, since callers mutate the flow before `perform` runs.
    private var reportedPhase: AgentCompactResumeFlow.Phase?

    init(
        agent: AgentTurnInterruptTarget,
        surfaceID: UUID,
        sessionID: String?,
        flow: AgentCompactResumeFlow,
        pane: Pane,
        settleInterval: Duration = AgentCompactResumeFlow.settleInterval,
        onPhaseChange: @escaping @MainActor (AgentCompactResumeFlow.Phase) -> Void
    ) {
        self.agent = agent
        self.surfaceID = surfaceID
        self.sessionID = sessionID
        self.flow = flow
        self.pane = pane
        self.settleInterval = settleInterval
        self.onPhaseChange = onPhaseChange
    }

    deinit {
        if let compactionObserver {
            NotificationCenter.default.removeObserver(compactionObserver)
        }
        deadline?.cancel()
        settleWait?.cancel()
    }

    var isFinished: Bool { flow.isFinished }

    /// Starts the run. A refusal comes back as a finished phase.
    func start() {
        compactionObserver = NotificationCenter.default.addObserver(
            forName: .agentCompactionFinished,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let report = AgentCompactionReport(notification: notification)
            MainActor.assumeIsolated {
                guard let self, let report, self.matches(report) else { return }
                // A finished manual compaction leaves the agent at its prompt
                // even if its journal still says running (the /compact
                // submit). Otherwise a running turn is never typed into.
                var lifecycle = self.pane.lifecycle()
                if lifecycle == .running, report.trigger == "manual" { lifecycle = .idle }
                self.perform(self.flow.compactionFinished(lifecycle: lifecycle, input: { self.pane.readInput() }))
            }
        }
        perform(flow.start(lifecycle: pane.lifecycle(), input: { self.pane.readInput() }))
    }

    /// Applies a change in the pane's journaled agent lifecycle.
    func lifecycleChanged() {
        guard !flow.isFinished else { return }
        perform(flow.lifecycleChanged(to: pane.lifecycle(), input: { self.pane.readInput() }))
    }

    /// Applies a PostCompact report, for tests that don't go through the Feed.
    func compactionFinishedForTesting() {
        perform(flow.compactionFinished(lifecycle: pane.lifecycle(), input: { self.pane.readInput() }))
    }

    /// Expires the current phase's deadline now, for tests.
    func timeOutForTesting() {
        perform(flow.timedOut())
    }

    func matches(_ report: AgentCompactionReport) -> Bool {
        // The agent's own auto-compaction is never the one this run asked for.
        guard report.source == agent.hookSource, report.trigger != "auto" else { return false }
        if let reported = report.surfaceID, reported == surfaceID { return true }
        return sessionID != nil && report.sessionID == sessionID
    }

    private func perform(_ steps: [AgentCompactResumeFlow.Step]) {
        for step in steps {
            switch step {
            case .interrupt:
                pane.interrupt()
            case .settle:
                settleWait?.cancel()
                settleWait = after(settleInterval) { run in
                    run.perform(run.flow.settled(lifecycle: run.pane.lifecycle(), input: { run.pane.readInput() }))
                }
            case .send(let text):
                pane.submit(text)
            case .finish:
                deadline?.cancel()
                settleWait?.cancel()
                if let compactionObserver {
                    NotificationCenter.default.removeObserver(compactionObserver)
                    self.compactionObserver = nil
                }
            }
        }
        // Each phase gets one deadline; settling is bounded by its own wait.
        if !flow.isFinished, flow.phase != deadlinePhase {
            deadline?.cancel()
            deadlinePhase = flow.phase
            deadline = flow.phaseTimeout.map { timeout in
                after(timeout) { run in run.perform(run.flow.timedOut()) }
            }
        }
        if flow.phase != reportedPhase {
            reportedPhase = flow.phase
            onPhaseChange(flow.phase)
        }
    }

    private func after(
        _ delay: Duration,
        _ body: @escaping @MainActor (AgentCompactResumeRun) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            body(self)
        }
    }
}

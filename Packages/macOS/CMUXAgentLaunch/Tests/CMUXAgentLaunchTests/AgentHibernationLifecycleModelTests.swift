import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite struct AgentHibernationLifecycleModelTests {
    // Minimal stand-ins for the app-target payload types the model is generic over.
    private struct Snap: Sendable, Equatable { let id: String }
    private struct Bind: Sendable, Equatable { let startup: String }
    private enum Life: Sendable, Equatable { case running, idle }

    private func makeModel() -> AgentHibernationLifecycleModel<Snap, Bind, Life> {
        AgentHibernationLifecycleModel<Snap, Bind, Life>()
    }

    @Test func acceptedSnapshotResumeStateReflectsCommandRunning() {
        let model = makeModel()
        #expect(model.resumeStateForAcceptedSnapshot(isCommandRunning: true) == .observedAgentCommandRunning)
        #expect(model.resumeStateForAcceptedSnapshot(isCommandRunning: false) == .manualResumeAvailable)
    }

    @Test func commandRunningAdvancesAwaitingToRunningWithoutInvalidation() {
        let model = makeModel()
        let panel = UUID()
        model.restoredAgentResumeStatesByPanelId[panel] = .awaitingAutoResumeCommand
        let invalidate = model.advanceResumeState(panelId: panel, isCommandRunning: true, isPromptIdle: false)
        #expect(invalidate == false)
        #expect(model.restoredAgentResumeStatesByPanelId[panel] == .autoResumeCommandRunning)
    }

    @Test func commandRunningOnManualOrNilRequestsInvalidation() {
        let model = makeModel()
        let manualPanel = UUID()
        model.restoredAgentResumeStatesByPanelId[manualPanel] = .manualResumeAvailable
        #expect(model.advanceResumeState(panelId: manualPanel, isCommandRunning: true, isPromptIdle: false))
        let nilPanel = UUID()
        #expect(model.advanceResumeState(panelId: nilPanel, isCommandRunning: true, isPromptIdle: false))
    }

    @Test func commandRunningOnAlreadyRunningIsNoop() {
        let model = makeModel()
        let panel = UUID()
        for state in [AgentHibernationLifecycleModel<Snap, Bind, Life>.RestoredAgentResumeState.autoResumeCommandRunning, .observedAgentCommandRunning] {
            model.restoredAgentResumeStatesByPanelId[panel] = state
            #expect(model.advanceResumeState(panelId: panel, isCommandRunning: true, isPromptIdle: false) == false)
            #expect(model.restoredAgentResumeStatesByPanelId[panel] == state)
        }
    }

    @Test func promptIdleInvalidatesRunningStatesOnly() {
        let model = makeModel()
        let runningPanel = UUID()
        model.restoredAgentResumeStatesByPanelId[runningPanel] = .autoResumeCommandRunning
        #expect(model.advanceResumeState(panelId: runningPanel, isCommandRunning: false, isPromptIdle: true))

        let observedPanel = UUID()
        model.restoredAgentResumeStatesByPanelId[observedPanel] = .observedAgentCommandRunning
        #expect(model.advanceResumeState(panelId: observedPanel, isCommandRunning: false, isPromptIdle: true))

        let awaitingPanel = UUID()
        model.restoredAgentResumeStatesByPanelId[awaitingPanel] = .awaitingAutoResumeCommand
        #expect(model.advanceResumeState(panelId: awaitingPanel, isCommandRunning: false, isPromptIdle: true) == false)

        let manualPanel = UUID()
        model.restoredAgentResumeStatesByPanelId[manualPanel] = .manualResumeAvailable
        #expect(model.advanceResumeState(panelId: manualPanel, isCommandRunning: false, isPromptIdle: true) == false)
    }

    @Test func neitherTransitionIsNoop() {
        let model = makeModel()
        let panel = UUID()
        model.restoredAgentResumeStatesByPanelId[panel] = .autoResumeCommandRunning
        #expect(model.advanceResumeState(panelId: panel, isCommandRunning: false, isPromptIdle: false) == false)
        #expect(model.restoredAgentResumeStatesByPanelId[panel] == .autoResumeCommandRunning)
    }

    @Test func clearRestoredAgentSnapshotDropsSnapshotAndResumeState() {
        let model = makeModel()
        let panel = UUID()
        model.restoredAgentSnapshotsByPanelId[panel] = Snap(id: "a")
        model.restoredAgentResumeStatesByPanelId[panel] = .manualResumeAvailable
        model.clearRestoredAgentSnapshot(panelId: panel)
        #expect(model.restoredAgentSnapshotsByPanelId[panel] == nil)
        #expect(model.restoredAgentResumeStatesByPanelId[panel] == nil)
    }

    // MARK: - Per-status lifecycle storage

    @Test func setLifecycleStoresStateAndNotifies() {
        let model = makeModel()
        let panel = UUID()
        var notified: [UUID] = []
        model.setLifecycle(key: "codex", panelId: panel, lifecycle: .running) { notified.append($0) }
        #expect(model.agentLifecycleStatesByPanelId[panel]?["codex"] == .running)
        #expect(notified == [panel])
    }

    @Test func clearLifecycleRemovesKeyPrunesEmptyPanelAndReportsClears() {
        let model = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        model.agentLifecycleStatesByPanelId[panelA] = ["codex": .running, "claude": .idle]
        model.agentLifecycleStatesByPanelId[panelB] = ["codex": .idle]
        var notified: [UUID] = []

        // Clear a single key on one panel: panel keeps its other key, so it is not pruned.
        #expect(model.clearLifecycle(key: "codex", panelId: panelA) { notified.append($0) })
        #expect(model.agentLifecycleStatesByPanelId[panelA] == ["claude": .idle])
        #expect(notified == [panelA])

        // Clearing an absent key reports false and does not notify.
        notified.removeAll()
        #expect(model.clearLifecycle(key: "missing", panelId: panelA) { notified.append($0) } == false)
        #expect(notified.isEmpty)

        // Clear across all panels: panelB's only key goes, so panelB is pruned.
        #expect(model.clearLifecycle(key: "codex", panelId: nil) { notified.append($0) })
        #expect(model.agentLifecycleStatesByPanelId[panelB] == nil)
    }

    @Test func clearLifecycleStatesRemovesPanelOnlyWhenPresent() {
        let model = makeModel()
        let panel = UUID()
        var notified: [UUID] = []
        model.clearLifecycleStates(panelId: panel) { notified.append($0) }
        #expect(notified.isEmpty)

        model.agentLifecycleStatesByPanelId[panel] = ["codex": .running]
        model.clearLifecycleStates(panelId: panel) { notified.append($0) }
        #expect(model.agentLifecycleStatesByPanelId[panel] == nil)
        #expect(notified == [panel])
    }

    @Test func clearAllLifecycleStatesNotifiesEachPanelOnce() {
        let model = makeModel()
        let panelA = UUID()
        let panelB = UUID()
        model.agentLifecycleStatesByPanelId[panelA] = ["codex": .running]
        model.agentLifecycleStatesByPanelId[panelB] = ["claude": .idle]
        var notified: Set<UUID> = []
        var count = 0
        model.clearAllLifecycleStates { notified.insert($0); count += 1 }
        #expect(model.agentLifecycleStatesByPanelId.isEmpty)
        #expect(notified == [panelA, panelB])
        #expect(count == 2)

        // No panels -> no notifications.
        count = 0
        model.clearAllLifecycleStates { _ in count += 1 }
        #expect(count == 0)
    }

    @Test func resolvedLifecycleStateFollowsPriorityThenFallback() {
        let model = makeModel()
        let panel = UUID()
        let priority: [Life] = [.running, .idle]

        // No states -> fallback.
        #expect(model.resolvedLifecycleState(panelId: panel, fallback: .idle, priority: priority) == .idle)

        // running wins over idle by priority order.
        model.agentLifecycleStatesByPanelId[panel] = ["a": .idle, "b": .running]
        #expect(model.resolvedLifecycleState(panelId: panel, fallback: nil, priority: priority) == .running)

        // Only idle present.
        model.agentLifecycleStatesByPanelId[panel] = ["a": .idle]
        #expect(model.resolvedLifecycleState(panelId: panel, fallback: nil, priority: priority) == .idle)
    }

    // MARK: - Surface resume binding storage

    @Test func surfaceResumeBindingRoundTrips() {
        let model = makeModel()
        let panel = UUID()
        #expect(model.surfaceResumeBinding(panelId: panel) == nil)
        model.setSurfaceResumeBinding(Bind(startup: "echo hi"), panelId: panel)
        #expect(model.surfaceResumeBinding(panelId: panel) == Bind(startup: "echo hi"))
        #expect(model.clearSurfaceResumeBinding(panelId: panel))
        #expect(model.surfaceResumeBinding(panelId: panel) == nil)
        #expect(model.clearSurfaceResumeBinding(panelId: panel) == false)
    }
}

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
}

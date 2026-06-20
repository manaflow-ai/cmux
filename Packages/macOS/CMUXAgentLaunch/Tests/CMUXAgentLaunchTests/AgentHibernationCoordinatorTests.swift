import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite struct AgentHibernationCoordinatorTests {
    // Minimal stand-ins for the app-target payload types.
    private struct Snap: Sendable, Equatable {
        let id: String
        var hasResumeCommand: Bool = true
    }
    private struct Bind: Sendable, Equatable {
        let startup: String?
        var matchesAgentHook: Bool = false
    }
    private enum Life: Sendable, Equatable { case running, needsInput, unknown, idle }

    /// Records every seam call and exposes the fixtures the orchestration reads.
    private final class FakeHost: AgentHibernationHosting {
        typealias Snapshot = Snap
        typealias Binding = Bind

        var existingPanels: Set<UUID> = []
        var focusedPanel: UUID?
        var canEnterHibernation: Set<UUID> = []
        var isHibernated: Set<UUID> = []
        var preparation: (didResume: Bool, queuedStartupInput: Bool) = (true, false)
        var agentPIDKeys: [UUID: Set<String>] = [:]
        var terminalPanelExists: Set<UUID> = []
        var commandRunning: Set<UUID> = []
        var autoResumeVisible = true
        var renderedVisible: Set<UUID> = []

        // Recorded effects.
        var lifecycleChanges: [UUID] = []
        var terminalFocusRecords: [UUID] = []
        var focused: [UUID] = []
        var enteredHibernation: [(UUID, Snap)] = []
        var clearedPIDs: [(String, UUID)] = []
        var refreshedPorts = 0
        var loggedInvalidations: [UUID] = []

        func agentHibernationPanelExists(_ panelId: UUID) -> Bool { existingPanels.contains(panelId) }
        func agentHibernationFocusedPanelId() -> UUID? { focusedPanel }
        func agentHibernationFocusPanel(_ panelId: UUID) { focused.append(panelId) }
        func agentHibernationRecordLifecycleChange(panelId: UUID) { lifecycleChanges.append(panelId) }
        func agentHibernationRecordTerminalFocus(panelId: UUID) { terminalFocusRecords.append(panelId) }
        func agentHibernationSnapshotFingerprint(_ snapshot: Snap) -> Int { snapshot.id.hashValue }
        func agentHibernationTerminalPanelCanEnterHibernation(panelId: UUID) -> Bool {
            canEnterHibernation.contains(panelId)
        }
        func agentHibernationEnterTerminalHibernation(panelId: UUID, agent: Snap, lastActivityAt: Date) {
            enteredHibernation.append((panelId, agent))
        }
        func agentHibernationTerminalPanelIsHibernated(panelId: UUID) -> Bool {
            isHibernated.contains(panelId)
        }
        func agentHibernationPrepareTerminalResume(panelId: UUID) -> (didResume: Bool, queuedStartupInput: Bool) {
            preparation
        }
        func agentHibernationAgentPIDKeys(panelId: UUID) -> Set<String> { agentPIDKeys[panelId] ?? [] }
        func agentHibernationClearAgentPID(key: String, panelId: UUID) { clearedPIDs.append((key, panelId)) }
        func agentHibernationRefreshTrackedAgentPorts() { refreshedPorts += 1 }
        func agentHibernationTerminalPanelExists(panelId: UUID) -> Bool {
            terminalPanelExists.contains(panelId)
        }
        func agentHibernationPanelShellIsCommandRunning(panelId: UUID) -> Bool {
            commandRunning.contains(panelId)
        }
        func agentHibernationAutoResumePresentationIsVisible() -> Bool { autoResumeVisible }
        func agentHibernationRenderedVisiblePanelIds() -> Set<UUID> { renderedVisible }
        func agentHibernationLogInvalidation(panelId: UUID, restoredAgent: Snap) {
            loggedInvalidations.append(panelId)
        }
        func agentHibernationResumeBindingMatchesAgentHook(panelId: UUID, restoredAgent: Snap) -> Bool {
            false
        }
        func agentHibernationResumeBindingHasStartupInput(_ binding: Bind) -> Bool {
            guard let startup = binding.startup else { return false }
            return !startup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func make() -> (AgentHibernationCoordinator<FakeHost, Life>, FakeHost,
                            AgentHibernationLifecycleModel<Snap, Bind, Life>) {
        let model = AgentHibernationLifecycleModel<Snap, Bind, Life>()
        let coordinator = AgentHibernationCoordinator<FakeHost, Life>(model: model)
        let host = FakeHost()
        coordinator.attach(host: host)
        return (coordinator, host, model)
    }

    @Test func setAgentLifecycleDefaultsToFocusedPanelAndGuardsExistence() {
        let (coordinator, host, model) = make()
        let focused = UUID()
        host.focusedPanel = focused
        host.existingPanels = [focused]

        coordinator.setAgentLifecycle(key: "codex", panelId: nil, lifecycle: .running)
        #expect(model.agentLifecycleStatesByPanelId[focused]?["codex"] == .running)
        #expect(host.lifecycleChanges == [focused])

        // A target panel that does not exist is a no-op.
        host.lifecycleChanges.removeAll()
        coordinator.setAgentLifecycle(key: "codex", panelId: UUID(), lifecycle: .idle)
        #expect(host.lifecycleChanges.isEmpty)
    }

    @Test func lifecycleStateUsesPriorityThenUnknownFallback() {
        let (coordinator, host, model) = make()
        let panel = UUID()
        host.existingPanels = [panel]
        model.agentLifecycleStatesByPanelId[panel] = ["a": .idle, "b": .running]
        #expect(
            coordinator.agentHibernationLifecycleState(
                panelId: panel,
                fallback: nil,
                priority: [.running, .needsInput, .unknown, .idle],
                unknown: .unknown
            ) == .running
        )
        // No states -> unknown fallback.
        #expect(
            coordinator.agentHibernationLifecycleState(
                panelId: UUID(),
                fallback: nil,
                priority: [.running, .needsInput, .unknown, .idle],
                unknown: .unknown
            ) == .unknown
        )
    }

    @Test func restorableAgentRespectsResumeCommandAndInvalidationFingerprint() {
        let (coordinator, host, model) = make()
        _ = host // retain the weakly-held host for the duration of the test
        let panel = UUID()
        let snap = Snap(id: "s1", hasResumeCommand: true)
        model.restoredAgentSnapshotsByPanelId[panel] = snap

        #expect(
            coordinator.restorableAgentForHibernation(
                panelId: panel,
                indexSnapshot: nil,
                snapshotHasResumeCommand: { $0.hasResumeCommand }
            ) == snap
        )

        // No resume command -> nil.
        let noCmd = Snap(id: "s2", hasResumeCommand: false)
        model.restoredAgentSnapshotsByPanelId[panel] = noCmd
        #expect(
            coordinator.restorableAgentForHibernation(
                panelId: panel,
                indexSnapshot: nil,
                snapshotHasResumeCommand: { $0.hasResumeCommand }
            ) == nil
        )

        // Invalidated fingerprint -> nil.
        model.restoredAgentSnapshotsByPanelId[panel] = snap
        model.invalidatedRestoredAgentFingerprintsByPanelId[panel] = snap.id.hashValue
        #expect(
            coordinator.restorableAgentForHibernation(
                panelId: panel,
                indexSnapshot: nil,
                snapshotHasResumeCommand: { $0.hasResumeCommand }
            ) == nil
        )
    }

    @Test func enterHibernationSeedsStateClearsPIDsAndRefreshesPorts() {
        let (coordinator, host, model) = make()
        let panel = UUID()
        host.canEnterHibernation = [panel]
        host.agentPIDKeys[panel] = ["claude_code"]
        let snap = Snap(id: "s1")

        coordinator.enterAgentHibernation(
            panelId: panel,
            agent: snap,
            lastActivityAt: Date(timeIntervalSince1970: 1),
            agentHasResumeCommand: { $0.hasResumeCommand }
        )

        #expect(model.restoredAgentSnapshotsByPanelId[panel] == snap)
        #expect(model.restoredAgentResumeStatesByPanelId[panel] == .manualResumeAvailable)
        #expect(host.clearedPIDs.map(\.0) == ["claude_code"])
        #expect(host.refreshedPorts == 1)
        #expect(host.enteredHibernation.count == 1)
    }

    @Test func enterHibernationNoopWhenPanelCannotEnter() {
        let (coordinator, host, model) = make()
        _ = host // retain the weakly-held host for the duration of the test
        let panel = UUID()
        coordinator.enterAgentHibernation(
            panelId: panel,
            agent: Snap(id: "s1"),
            lastActivityAt: Date(),
            agentHasResumeCommand: { _ in true }
        )
        #expect(model.restoredAgentSnapshotsByPanelId[panel] == nil)
    }

    @Test func resumeQueuedInputMovesToAwaitingAndRecordsFocus() {
        let (coordinator, host, model) = make()
        let panel = UUID()
        host.isHibernated = [panel]
        host.preparation = (didResume: true, queuedStartupInput: true)
        model.restoredAgentSnapshotsByPanelId[panel] = Snap(id: "s1")

        #expect(coordinator.resumeAgentHibernation(panelId: panel, focus: true))
        #expect(model.restoredAgentResumeStatesByPanelId[panel] == .awaitingAutoResumeCommand)
        #expect(host.terminalFocusRecords == [panel])
        #expect(host.focused == [panel])
    }

    @Test func resumeReturnsFalseWhenPreparationDidNotResume() {
        let (coordinator, host, _) = make()
        let panel = UUID()
        host.isHibernated = [panel]
        host.preparation = (didResume: false, queuedStartupInput: false)
        #expect(coordinator.resumeAgentHibernation(panelId: panel, focus: false) == false)
        #expect(host.terminalFocusRecords.isEmpty)
    }

    @Test func acceptedSnapshotResumeStateTracksShellActivity() {
        let (coordinator, host, _) = make()
        let panel = UUID()
        host.commandRunning = [panel]
        #expect(coordinator.restoredAgentResumeStateForAcceptedSnapshot(panelId: panel) == .observedAgentCommandRunning)
        #expect(coordinator.restoredAgentResumeStateForAcceptedSnapshot(panelId: UUID()) == .manualResumeAvailable)
    }

    @Test func updateResumeStateInvalidatesWhenProgressionDemands() {
        let (coordinator, host, model) = make()
        let panel = UUID()
        let snap = Snap(id: "s1")
        model.restoredAgentSnapshotsByPanelId[panel] = snap
        model.restoredAgentResumeStatesByPanelId[panel] = .manualResumeAvailable

        coordinator.updateRestoredAgentResumeState(
            panelId: panel,
            restoredAgent: snap,
            isCommandRunning: true,
            isPromptIdle: false
        )
        // manualResumeAvailable + commandRunning -> invalidate.
        #expect(model.restoredAgentSnapshotsByPanelId[panel] == nil)
        #expect(model.invalidatedRestoredAgentFingerprintsByPanelId[panel] == snap.id.hashValue)
        #expect(host.loggedInvalidations == [panel])
    }

    @Test func setSurfaceResumeBindingGuardsTerminalAndStartupInput() {
        let (coordinator, host, model) = make()
        let panel = UUID()
        host.terminalPanelExists = [panel]

        // Blank startup input -> rejected.
        #expect(coordinator.setSurfaceResumeBinding(Bind(startup: "   "), panelId: panel) == false)
        #expect(model.surfaceResumeBinding(panelId: panel) == nil)

        // Valid -> stored.
        #expect(coordinator.setSurfaceResumeBinding(Bind(startup: "echo hi"), panelId: panel))
        #expect(model.surfaceResumeBinding(panelId: panel) == Bind(startup: "echo hi"))

        // No terminal -> rejected.
        #expect(coordinator.setSurfaceResumeBinding(Bind(startup: "echo hi"), panelId: UUID()) == false)
    }

    @Test func visiblePanelIdsEmptyWhenAutoResumeHidden() {
        let (coordinator, host, _) = make()
        host.renderedVisible = [UUID()]
        host.autoResumeVisible = false
        #expect(coordinator.agentHibernationVisiblePanelIdsForCurrentLayout().isEmpty)
        host.autoResumeVisible = true
        #expect(coordinator.agentHibernationVisiblePanelIdsForCurrentLayout() == host.renderedVisible)
    }
}

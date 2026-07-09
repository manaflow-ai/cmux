import Foundation
import Testing
@testable import CmuxWorkspaces

/// In-memory window host: a dictionary of workspaces/panels plus records of
/// the focus/unfocus mutations and DEBUG events the model drives.
@MainActor
private final class FakeFocusedSurfaceHost: FocusedSurfaceHosting {
    struct WorkspaceState {
        var panels: Set<UUID>
        var focusedPanelId: UUID?
    }

    var workspaces: [UUID: WorkspaceState] = [:]
    var selectedWorkspaceId: UUID?
    var focusedPanels: [(workspaceId: UUID, panelId: UUID)] = []
    var unfocusedPanels: [(workspaceId: UUID, panelId: UUID)] = []
    var events: [PendingWorkspaceUnfocusEvent] = []

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        workspaces[workspaceId]?.panels.contains(panelId) ?? false
    }

    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        workspaces[workspaceId]?.focusedPanelId
    }

    func focusPanel(workspaceId: UUID, panelId: UUID) {
        focusedPanels.append((workspaceId, panelId))
    }

    func unfocusPanel(workspaceId: UUID, panelId: UUID) {
        guard panelExists(workspaceId: workspaceId, panelId: panelId) else { return }
        unfocusedPanels.append((workspaceId, panelId))
    }

    func logPendingWorkspaceUnfocusEvent(_ event: PendingWorkspaceUnfocusEvent) {
        events.append(event)
    }
}

@MainActor
private func makeModel() -> (FocusedSurfaceModel, FakeFocusedSurfaceHost) {
    let host = FakeFocusedSurfaceHost()
    let model = FocusedSurfaceModel()
    model.attach(host: host)
    return (model, host)
}

@Suite(.serialized)
@MainActor
struct FocusedSurfaceModelTests {
    @Test func remembersAndForgetsFocusedSurface() {
        let (model, _) = makeModel()
        let ws = UUID()
        let panel = UUID()
        #expect(model.rememberedFocusedPanelId(ws) == nil)
        model.rememberFocusedSurface(workspaceId: ws, surfaceId: panel)
        #expect(model.rememberedFocusedPanelId(ws) == panel)
        model.forgetRememberedFocus(workspaceId: ws)
        #expect(model.rememberedFocusedPanelId(ws) == nil)
    }

    @Test func recordsRememberedFocusFromWorkspaceFocusedPanel() {
        let (model, host) = makeModel()
        let ws = UUID()
        let panel = UUID()
        host.workspaces[ws] = .init(panels: [panel], focusedPanelId: panel)
        model.recordRememberedFocusForPreviousSelection(ws)
        #expect(model.rememberedFocusedPanelId(ws) == panel)
    }

    @Test func recordPreviousSelectionIsNoOpWhenNoFocusedPanel() {
        let (model, host) = makeModel()
        let ws = UUID()
        host.workspaces[ws] = .init(panels: [], focusedPanelId: nil)
        model.recordRememberedFocusForPreviousSelection(ws)
        #expect(model.rememberedFocusedPanelId(ws) == nil)
    }

    @Test func focusSelectedRestoresRememberedPanelOverWorkspaceFocus() {
        let (model, host) = makeModel()
        let ws = UUID()
        let remembered = UUID()
        let focused = UUID()
        host.workspaces[ws] = .init(panels: [remembered, focused], focusedPanelId: focused)
        host.selectedWorkspaceId = ws
        model.rememberFocusedSurface(workspaceId: ws, surfaceId: remembered)
        model.focusSelectedWorkspacePanel(previousWorkspaceId: nil)
        #expect(host.focusedPanels.count == 1)
        #expect(host.focusedPanels.first?.panelId == remembered)
    }

    @Test func focusSelectedFallsBackToWorkspaceFocusedPanel() {
        let (model, host) = makeModel()
        let ws = UUID()
        let focused = UUID()
        host.workspaces[ws] = .init(panels: [focused], focusedPanelId: focused)
        host.selectedWorkspaceId = ws
        // Remembered panel no longer exists in the workspace -> fall back.
        model.rememberFocusedSurface(workspaceId: ws, surfaceId: UUID())
        model.focusSelectedWorkspacePanel(previousWorkspaceId: nil)
        #expect(host.focusedPanels.first?.panelId == focused)
    }

    @Test func focusSelectedIsNoOpWhenNoResolvablePanel() {
        let (model, host) = makeModel()
        let ws = UUID()
        host.workspaces[ws] = .init(panels: [], focusedPanelId: nil)
        host.selectedWorkspaceId = ws
        model.focusSelectedWorkspacePanel(previousWorkspaceId: nil)
        #expect(host.focusedPanels.isEmpty)
    }

    @Test func focusSelectedDefersPreviousWorkspaceUnfocus() {
        let (model, host) = makeModel()
        let previous = UUID()
        let prevPanel = UUID()
        let selected = UUID()
        let selPanel = UUID()
        host.workspaces[previous] = .init(panels: [prevPanel], focusedPanelId: prevPanel)
        host.workspaces[selected] = .init(panels: [selPanel], focusedPanelId: selPanel)
        host.selectedWorkspaceId = selected
        model.focusSelectedWorkspacePanel(previousWorkspaceId: previous)
        // Deferred, not yet unfocused.
        #expect(host.unfocusedPanels.isEmpty)
        #expect(host.events.count == 1)
        guard case let .deferred(wid, pid) = host.events.first else {
            Issue.record("expected deferred event")
            return
        }
        #expect(wid == previous)
        #expect(pid == prevPanel)
        // Completion unfocuses the deferred previous workspace panel.
        model.completePendingWorkspaceUnfocus(reason: "test")
        #expect(host.unfocusedPanels.count == 1)
        #expect(host.unfocusedPanels.first?.workspaceId == previous)
        guard case .completed = host.events.last else {
            Issue.record("expected completed event")
            return
        }
    }

    @Test func completeIsDroppedWhenPendingTabSelectedAgain() {
        let (model, host) = makeModel()
        let previous = UUID()
        let prevPanel = UUID()
        let selected = UUID()
        let selPanel = UUID()
        host.workspaces[previous] = .init(panels: [prevPanel], focusedPanelId: prevPanel)
        host.workspaces[selected] = .init(panels: [selPanel], focusedPanelId: selPanel)
        host.selectedWorkspaceId = selected
        model.focusSelectedWorkspacePanel(previousWorkspaceId: previous)
        // The previously-unfocusing workspace becomes selected again.
        host.selectedWorkspaceId = previous
        model.completePendingWorkspaceUnfocus(reason: "test")
        #expect(host.unfocusedPanels.isEmpty)
        guard case .droppedSelectedAgain = host.events.last else {
            Issue.record("expected droppedSelectedAgain event")
            return
        }
    }

    @Test func replacingPendingFlushesStaleNonSelectedTarget() {
        let (model, host) = makeModel()
        let first = UUID()
        let firstPanel = UUID()
        let second = UUID()
        let secondPanel = UUID()
        let selected = UUID()
        let selPanel = UUID()
        host.workspaces[first] = .init(panels: [firstPanel], focusedPanelId: firstPanel)
        host.workspaces[second] = .init(panels: [secondPanel], focusedPanelId: secondPanel)
        host.workspaces[selected] = .init(panels: [selPanel], focusedPanelId: selPanel)
        host.selectedWorkspaceId = selected
        model.focusSelectedWorkspacePanel(previousWorkspaceId: first)
        model.focusSelectedWorkspacePanel(previousWorkspaceId: second)
        // The first (stale, not selected) target was flushed when replaced.
        #expect(host.unfocusedPanels.count == 1)
        #expect(host.unfocusedPanels.first?.workspaceId == first)
        #expect(host.events.contains { if case .flushedOnReplace = $0 { return true } else { return false } })
    }

    @Test func resetClearsRememberedAndPending() {
        let (model, host) = makeModel()
        let previous = UUID()
        let prevPanel = UUID()
        let selected = UUID()
        let selPanel = UUID()
        host.workspaces[previous] = .init(panels: [prevPanel], focusedPanelId: prevPanel)
        host.workspaces[selected] = .init(panels: [selPanel], focusedPanelId: selPanel)
        host.selectedWorkspaceId = selected
        model.rememberFocusedSurface(workspaceId: selected, surfaceId: selPanel)
        model.focusSelectedWorkspacePanel(previousWorkspaceId: previous)
        model.reset()
        #expect(model.rememberedFocusedPanelId(selected) == nil)
        // After reset there is no pending target to complete.
        host.unfocusedPanels.removeAll()
        model.completePendingWorkspaceUnfocus(reason: "after_reset")
        #expect(host.unfocusedPanels.isEmpty)
    }

    @Test func shouldUnfocusPredicateMatchesLegacy() {
        let a = UUID()
        let b = UUID()
        #expect(FocusedSurfaceModel.shouldUnfocusPendingWorkspace(pendingTabId: a, selectedTabId: b))
        #expect(!FocusedSurfaceModel.shouldUnfocusPendingWorkspace(pendingTabId: a, selectedTabId: a))
        #expect(FocusedSurfaceModel.shouldUnfocusPendingWorkspace(pendingTabId: a, selectedTabId: nil))
    }
}

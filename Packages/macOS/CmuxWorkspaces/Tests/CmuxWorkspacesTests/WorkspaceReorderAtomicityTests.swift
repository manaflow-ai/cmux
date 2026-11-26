import Foundation
import Testing

@testable import CmuxWorkspaces

/// Captures the snapshots that a window-side observer would receive while a
/// workspace reorder is applied.  The app's ContentView uses the same
/// willSet boundary to decide which workspace portals remain mounted.
@MainActor
private final class ReorderPublicationHost: WorkspacesHosting, WorkspaceOrderHosting {
    typealias Tab = CoordinatorStubTab

    private(set) var tabSnapshots: [[UUID]] = []
    private(set) var orderChanges: [[UUID]] = []

    func resetSnapshots() {
        tabSnapshots.removeAll()
        orderChanges.removeAll()
    }

    func workspaceTabsWillChange(to newValue: [CoordinatorStubTab]) {
        tabSnapshots.append(newValue.map(\.id))
    }

    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {}
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {}
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {}

    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        orderChanges.append(movedWorkspaceIds)
    }
}

@MainActor
struct WorkspaceReorderAtomicityTests {
    private func makeWorld() -> (
        model: WorkspacesModel<CoordinatorStubTab>,
        host: ReorderPublicationHost,
        reorder: WorkspaceReorderCoordinator<CoordinatorStubTab>
    ) {
        let model = WorkspacesModel<CoordinatorStubTab>()
        let host = ReorderPublicationHost()
        model.attach(host: host)
        let reorder = WorkspaceReorderCoordinator(model: model)
        reorder.attach(host: host)
        return (model, host, reorder)
    }

    @Test
    func notificationReorderPublishesOnlyCoherentWorkspaceSnapshots() {
        let (model, host, reorder) = makeWorld()

        let first = CoordinatorStubTab()
        let selected = CoordinatorStubTab()
        let last = CoordinatorStubTab()
        model.tabs = [first, selected, last]
        model.selectedTabId = selected.id
        host.resetSnapshots()

        reorder.moveTabToTopForNotification(selected.id)

        #expect(host.tabSnapshots == [[selected.id, first.id, last.id]])
        #expect(host.tabSnapshots.allSatisfy { $0.contains(selected.id) })
        #expect(host.orderChanges == [[selected.id]])
    }

    @Test
    func explicitReorderPublishesOnlyCoherentWorkspaceSnapshots() {
        let (model, host, reorder) = makeWorld()
        let first = CoordinatorStubTab()
        let selected = CoordinatorStubTab()
        let last = CoordinatorStubTab()
        model.tabs = [first, selected, last]
        model.selectedTabId = selected.id
        host.resetSnapshots()

        #expect(reorder.reorderWorkspace(tabId: selected.id, toIndex: 0))

        #expect(host.tabSnapshots == [[selected.id, first.id, last.id]])
        #expect(host.tabSnapshots.allSatisfy { $0.contains(selected.id) })
    }

    @Test
    func pinTransitionPublishesOnlyCoherentWorkspaceSnapshots() {
        let (model, host, reorder) = makeWorld()
        let pinned = CoordinatorStubTab(isPinned: true)
        let selected = CoordinatorStubTab()
        let last = CoordinatorStubTab()
        model.tabs = [pinned, selected, last]
        model.selectedTabId = selected.id
        host.resetSnapshots()

        reorder.setPinned(selected, pinned: true)

        #expect(host.tabSnapshots == [[pinned.id, selected.id, last.id]])
        #expect(model.tabs.map(\.id) == [pinned.id, selected.id, last.id])
    }
}

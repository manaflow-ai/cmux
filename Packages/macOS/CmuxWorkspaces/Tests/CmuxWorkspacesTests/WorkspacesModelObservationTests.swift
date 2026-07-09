import Foundation
import Testing
@testable import CmuxWorkspaces

/// Minimal `WorkspaceTabRepresenting` stub for the observation tests; the
/// model only needs an `id` and the protocol's no-op surface here.
@MainActor
private final class ObservationStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool = false
    var currentDirectory: String = "/tmp"
    var title: String = ""
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]

    init(id: UUID = UUID()) { self.id = id }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
    func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
    func applyProcessTitle(_ title: String) {}
    func panelExists(_ panelId: UUID) -> Bool { false }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { nil }
}

private func makeGroup(_ name: String) -> WorkspaceGroup {
    WorkspaceGroup(
        id: UUID(),
        name: name,
        isCollapsed: false,
        isPinned: false,
        anchorWorkspaceId: UUID(),
        customColor: nil,
        iconSymbol: nil
    )
}

/// Emission-parity coverage for the `@Observable` observation helpers that
/// replaced the retired `TabManager.tabsPublisher` / `selectedTabIdPublisher` /
/// `workspaceGroupsPublisher` `CurrentValueSubject` bridges. The bridges fired
/// during `willSet` and replayed on subscribe; the helpers fire after the change
/// commits and do not replay. These tests pin the contract documented on
/// ``WorkspacesModel/observeTabs(_:)``.
@MainActor
struct WorkspacesModelObservationTests {
    /// Lets the `Task { @MainActor }` hop inside the observation helper run, so
    /// the change handler has been delivered before assertions.
    private func drain() async {
        await Task.yield()
        await Task.yield()
    }

    @Test
    func tabsObservationFiresAfterEachMutationReadingCommittedValue() async {
        let model = WorkspacesModel<ObservationStubTab>()
        var seenCounts: [Int] = []
        let token = model.observeTabs { seenCounts.append(model.tabs.count) }

        // No replay on subscribe.
        await drain()
        #expect(seenCounts.isEmpty)

        model.tabs = [ObservationStubTab()]
        await drain()
        model.tabs = [ObservationStubTab(), ObservationStubTab()]
        await drain()

        // Each mutation delivered once; the handler read the committed
        // post-change count (1 then 2), never a willSet-time old value.
        #expect(seenCounts == [1, 2])
        token.cancel()
    }

    @Test
    func tabsObservationFiresOnEqualValueAssignment() async {
        let model = WorkspacesModel<ObservationStubTab>()
        let tab = ObservationStubTab()
        model.tabs = [tab]

        var fireCount = 0
        let token = model.observeTabs { fireCount += 1 }

        // Re-assign an equal array (same element). The bridge's `.send` fired on
        // equal assignment; the `@Observable` macro records a mutation on every
        // set, so the watch fires too.
        model.tabs = [tab]
        await drain()
        model.tabs = [tab]
        await drain()

        #expect(fireCount == 2)
        token.cancel()
    }

    @Test
    func selectedTabIdObservationReArmsAcrossManyChanges() async {
        let model = WorkspacesModel<ObservationStubTab>()
        var seen: [UUID?] = []
        let token = model.observeSelectedTabId { seen.append(model.selectedTabId) }

        let a = UUID()
        let b = UUID()
        model.selectedTabId = a
        await drain()
        model.selectedTabId = b
        await drain()
        model.selectedTabId = nil
        await drain()

        // The watch re-arms after every delivery, so all three transitions land.
        #expect(seen == [a, b, nil])
        token.cancel()
    }

    @Test
    func workspaceGroupsObservationStopsAfterCancel() async {
        let model = WorkspacesModel<ObservationStubTab>()
        var fireCount = 0
        let token = model.observeWorkspaceGroups { fireCount += 1 }

        model.workspaceGroups = [makeGroup("g1")]
        await drain()
        #expect(fireCount == 1)

        token.cancel()
        model.workspaceGroups = [makeGroup("g2")]
        await drain()
        // No further delivery after cancel.
        #expect(fireCount == 1)
    }

    @Test
    func droppingTheHandleStopsDelivery() async {
        let model = WorkspacesModel<ObservationStubTab>()
        var fireCount = 0
        do {
            let token = model.observeTabs { fireCount += 1 }
            model.tabs = [ObservationStubTab()]
            await drain()
            #expect(fireCount == 1)
            _ = token
        }
        // The handle is gone; the watch tears down and no callback fires.
        model.tabs = [ObservationStubTab(), ObservationStubTab()]
        await drain()
        #expect(fireCount == 1)
    }

    @Test
    func observationsAreIndependentPerProperty() async {
        let model = WorkspacesModel<ObservationStubTab>()
        var tabsFires = 0
        var selectionFires = 0
        let tabsToken = model.observeTabs { tabsFires += 1 }
        let selectionToken = model.observeSelectedTabId { selectionFires += 1 }

        // A tabs change must not trip the selection watch and vice versa.
        model.tabs = [ObservationStubTab()]
        await drain()
        #expect(tabsFires == 1)
        #expect(selectionFires == 0)

        model.selectedTabId = UUID()
        await drain()
        #expect(tabsFires == 1)
        #expect(selectionFires == 1)

        tabsToken.cancel()
        selectionToken.cancel()
    }
}

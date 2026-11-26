import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

@MainActor
private final class RecordingPaneTreeHost: PaneTreeHosting {
    typealias Panel = String
    private(set) var panelsWillChangeCount = 0
    private(set) var lastPanelsNewValue: [UUID: String] = [:]
    private(set) var panelsValueAtHookTime: [UUID: String] = [:]
    private(set) var versionWillChangeCount = 0
    private(set) var lastVersionNewValue = 0
    private(set) var versionValueAtHookTime = 0
    var model: PaneTreeModel<String>?

    func panelsWillChange(to newValue: [UUID: String]) {
        panelsWillChangeCount += 1
        lastPanelsNewValue = newValue
        if let model { panelsValueAtHookTime = model.panels }
    }

    func paneLayoutVersionWillChange(to newValue: Int) {
        versionWillChangeCount += 1
        lastVersionNewValue = newValue
        if let model { versionValueAtHookTime = model.paneLayoutVersion }
    }
}

@MainActor
@Suite("PaneTreeModel")
struct PaneTreeModelTests {
    /// The hooks replace `@Published` willSet observers: they must see the
    /// new value as an argument while the property still reads the OLD value.
    @Test func hooksFireAtWillSetTimeWithNewValue() {
        let host = RecordingPaneTreeHost()
        let model = PaneTreeModel<String>()
        host.model = model
        model.attach(host: host)

        let id = UUID()
        model.panels = [id: "terminal"]
        #expect(host.panelsWillChangeCount == 1)
        #expect(host.lastPanelsNewValue == [id: "terminal"])
        #expect(host.panelsValueAtHookTime == [:])

        model.paneLayoutVersion = 7
        #expect(host.versionWillChangeCount == 1)
        #expect(host.lastVersionNewValue == 7)
        #expect(host.versionValueAtHookTime == 0)
    }

    /// `@Published` fired on every assignment, never comparing; the hooks
    /// must keep equal-assignment emissions.
    @Test func hooksFireOnEqualAssignment() {
        let host = RecordingPaneTreeHost()
        let model = PaneTreeModel<String>()
        host.model = model
        model.attach(host: host)

        model.paneLayoutVersion = 0
        model.paneLayoutVersion = 0
        #expect(host.versionWillChangeCount == 2)

        model.panels = [:]
        #expect(host.panelsWillChangeCount == 1)
    }

    /// Mutations before attach fire no hooks (legacy: observers subscribed
    /// after init saw no init-time emissions besides replay).
    @Test func mutationsBeforeAttachFireNoHooks() {
        let host = RecordingPaneTreeHost()
        let model = PaneTreeModel<String>()
        model.panels = [UUID(): "browser"]
        model.attach(host: host)
        #expect(host.panelsWillChangeCount == 0)
    }

    /// The non-published bookkeeping stores round-trip unchanged.
    @Test func bookkeepingStoresRoundTrip() {
        let model = PaneTreeModel<String>()
        let tabId = TabID()
        let panelId = UUID()
        model.bindSurface(tabId, toPanelId: panelId)
        #expect(model.surfaceIdToPanelId[tabId] == panelId)
        model.lastOrderedPanelIds = [panelId]
        #expect(model.lastOrderedPanelIds == [panelId])
    }

    /// The registry queries resolve through the surface-id mapping exactly
    /// like the legacy `Workspace.panelIdFromSurfaceId` /
    /// `surfaceIdFromPanelId` accessors.
    @Test func registryQueriesResolveTheMapping() {
        let model = PaneTreeModel<String>()
        let tabId = TabID()
        let panelId = UUID()
        model.bindSurface(tabId, toPanelId: panelId)

        #expect(model.panelId(forSurfaceId: tabId) == panelId)
        #expect(model.surfaceId(forPanelId: panelId) == tabId)
        #expect(model.panelId(forSurfaceId: TabID()) == nil)
        #expect(model.surfaceId(forPanelId: UUID()) == nil)
    }

    /// Rebinding one live panel to a new bonsplit surface must not leave the
    /// old surface id resolving to the same panel.
    @Test func rebindingPanelToNewSurfaceInvalidatesOldSurfaceMapping() {
        let model = PaneTreeModel<String>()
        let oldTabId = TabID()
        let newTabId = TabID()
        let panelId = UUID()

        model.bindSurface(oldTabId, toPanelId: panelId)
        model.bindSurface(newTabId, toPanelId: panelId)

        #expect(model.panelId(forSurfaceId: oldTabId) == nil)
        #expect(model.panelId(forSurfaceId: newTabId) == panelId)
        #expect(model.surfaceId(forPanelId: panelId) == newTabId)
    }

    /// Reusing one bonsplit surface for a different panel must also clear the
    /// old panel's reverse lookup.
    @Test func rebindingSurfaceToNewPanelInvalidatesOldPanelMapping() {
        let model = PaneTreeModel<String>()
        let tabId = TabID()
        let oldPanelId = UUID()
        let newPanelId = UUID()

        model.bindSurface(tabId, toPanelId: oldPanelId)
        model.bindSurface(tabId, toPanelId: newPanelId)

        #expect(model.panelId(forSurfaceId: tabId) == newPanelId)
        #expect(model.surfaceId(forPanelId: oldPanelId) == nil)
        #expect(model.surfaceId(forPanelId: newPanelId) == tabId)
    }

    /// Close cleanup removes the surface owned by the closed panel.
    @Test func closedPanelCleanupRemovesClosedSurfaceMapping() {
        let model = PaneTreeModel<String>()
        let closedPanelTabId = TabID()
        let closedPanelId = UUID()

        model.bindSurface(closedPanelTabId, toPanelId: closedPanelId)
        model.removeSurfaceMappings(forPanelId: closedPanelId)

        #expect(model.panelId(forSurfaceId: closedPanelTabId) == nil)
        #expect(model.surfaceId(forPanelId: closedPanelId) == nil)
    }

    /// Close cleanup removes stale aliases for the closed panel without using
    /// a stale tab id to drop a surface that has already moved to another panel.
    @Test func closedPanelCleanupKeepsReboundSurfaceMapping() {
        let model = PaneTreeModel<String>()
        let reboundTabId = TabID()
        let closedPanelId = UUID()
        let livePanelId = UUID()

        model.bindSurface(reboundTabId, toPanelId: closedPanelId)
        model.bindSurface(reboundTabId, toPanelId: livePanelId)

        model.removeSurfaceMappings(forPanelId: closedPanelId)

        #expect(model.panelId(forSurfaceId: reboundTabId) == livePanelId)
        #expect(model.surfaceId(forPanelId: closedPanelId) == nil)
        #expect(model.surfaceId(forPanelId: livePanelId) == reboundTabId)
    }
}

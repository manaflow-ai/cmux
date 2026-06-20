import Foundation
import Testing
import Bonsplit
@testable import CmuxWorkspaces

/// Verifies the lifted ``SurfaceLifecycleCoordinator`` resolvers behave exactly
/// like the legacy `Workspace` Panel-Operations bodies over a synthetic split
/// tree built directly as bonsplit snapshot values.
@MainActor
struct SurfaceLifecycleCoordinatorTests {
    /// A deterministic fake split tree: panel ids map 1:1 to surface ids, panes
    /// hold ordered surface ids, and the tree/layout snapshots are supplied
    /// verbatim. Records divider writes for assertion.
    final class FakeHost: SurfaceLifecycleHosting {
        var surfaceForPanel: [UUID: TabID] = [:]
        var panes: [PaneID] = []
        var tabsByPane: [PaneID: [Bonsplit.Tab]] = [:]
        var tree: ExternalTreeNode = .pane(
            ExternalPaneNode(id: UUID().uuidString, frame: PixelRect(x: 0, y: 0, width: 1, height: 1), tabs: [], selectedTabId: nil)
        )
        var layout: LayoutSnapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 1, height: 1),
            panes: [],
            focusedPaneId: nil,
            timestamp: 0
        )
        var dividerWrites: [(position: CGFloat, splitId: UUID)] = []
        var dividerWriteReturns = true

        var definedProfileIDs: Set<UUID> = []
        var effectiveLastUsedProfileID = UUID()
        var preferredBrowserProfileID: UUID?
        var preferredWrites: [UUID?] = []
        var sourcePanelProfileID: [UUID: UUID] = [:]

        func surfaceId(forPanelId panelId: UUID) -> TabID? { surfaceForPanel[panelId] }
        var allBonsplitPaneIds: [PaneID] { panes }
        func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab] { tabsByPane[paneId] ?? [] }
        func treeSnapshot() -> ExternalTreeNode { tree }
        func layoutSnapshot() -> LayoutSnapshot { layout }
        func applySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID) -> Bool {
            dividerWrites.append((position, splitId))
            return dividerWriteReturns
        }
        func surfaceLifecycleProfileDefinitionExists(id: UUID) -> Bool {
            definedProfileIDs.contains(id)
        }
        var surfaceLifecycleEffectiveLastUsedProfileID: UUID { effectiveLastUsedProfileID }
        var surfaceLifecyclePreferredBrowserProfileID: UUID? { preferredBrowserProfileID }
        func surfaceLifecycleSetPreferredBrowserProfileID(_ profileID: UUID?) {
            preferredWrites.append(profileID)
            preferredBrowserProfileID = profileID
        }
        func surfaceLifecycleSourcePanelProfileID(panelId: UUID) -> UUID? {
            sourcePanelProfileID[panelId]
        }
    }

    private func makeTab(_ id: UUID) -> Bonsplit.Tab {
        Bonsplit.Tab(id: TabID(uuid: id), title: "t")
    }

    @Test func paneIdResolvesOwningPaneAndNilWhenAbsent() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let panelA = UUID(), surfaceA = UUID()
        let panelB = UUID(), surfaceB = UUID()
        let pane0 = PaneID(), pane1 = PaneID()
        host.surfaceForPanel = [panelA: TabID(uuid: surfaceA), panelB: TabID(uuid: surfaceB)]
        host.panes = [pane0, pane1]
        host.tabsByPane = [pane0: [makeTab(surfaceA)], pane1: [makeTab(surfaceB)]]

        #expect(coordinator.paneId(forPanelId: panelA) == pane0)
        #expect(coordinator.paneId(forPanelId: panelB) == pane1)
        #expect(coordinator.paneId(forPanelId: UUID()) == nil)
    }

    @Test func indexInPaneMatchesTabOrder() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let p0 = UUID(), p1 = UUID(), p2 = UUID()
        let s0 = UUID(), s1 = UUID(), s2 = UUID()
        let pane = PaneID()
        host.surfaceForPanel = [p0: TabID(uuid: s0), p1: TabID(uuid: s1), p2: TabID(uuid: s2)]
        host.panes = [pane]
        host.tabsByPane = [pane: [makeTab(s0), makeTab(s1), makeTab(s2)]]

        #expect(coordinator.indexInPane(forPanelId: p0) == 0)
        #expect(coordinator.indexInPane(forPanelId: p1) == 1)
        #expect(coordinator.indexInPane(forPanelId: p2) == 2)
        #expect(coordinator.indexInPane(forPanelId: UUID()) == nil)
    }

    @Test func applyInitialSplitDividerWritesWhenJoinedAndNoOpsOnNilPosition() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let leftPane = PaneID(), rightPane = PaneID()
        let splitId = UUID()
        host.tree = .split(
            ExternalSplitNode(
                id: splitId.uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: .pane(ExternalPaneNode(id: leftPane.id.uuidString, frame: PixelRect(x: 0, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil)),
                second: .pane(ExternalPaneNode(id: rightPane.id.uuidString, frame: PixelRect(x: 0.5, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil))
            )
        )

        coordinator.applyInitialSplitDividerPosition(nil, sourcePaneId: leftPane, newPaneId: rightPane)
        #expect(host.dividerWrites.isEmpty)

        coordinator.applyInitialSplitDividerPosition(0.3, sourcePaneId: leftPane, newPaneId: rightPane)
        #expect(host.dividerWrites.count == 1)
        #expect(host.dividerWrites.first?.position == 0.3)
        #expect(host.dividerWrites.first?.splitId == splitId)
    }

    @Test func preferredRightSideTargetPaneFindsHorizontalSibling() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let leftPane = PaneID(), rightPane = PaneID()
        let leftPanel = UUID(), leftSurface = UUID()
        host.surfaceForPanel = [leftPanel: TabID(uuid: leftSurface)]
        host.panes = [leftPane, rightPane]
        host.tabsByPane = [leftPane: [makeTab(leftSurface)], rightPane: []]
        let leftNode = ExternalPaneNode(id: leftPane.id.uuidString, frame: PixelRect(x: 0, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil)
        let rightNode = ExternalPaneNode(id: rightPane.id.uuidString, frame: PixelRect(x: 0.5, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil)
        host.tree = .split(
            ExternalSplitNode(id: UUID().uuidString, orientation: "horizontal", dividerPosition: 0.5, first: .pane(leftNode), second: .pane(rightNode))
        )
        host.layout = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 1, height: 1),
            panes: [
                PaneGeometry(paneId: leftPane.id.uuidString, frame: PixelRect(x: 0, y: 0, width: 0.5, height: 1), selectedTabId: nil, tabIds: []),
                PaneGeometry(paneId: rightPane.id.uuidString, frame: PixelRect(x: 0.5, y: 0, width: 0.5, height: 1), selectedTabId: nil, tabIds: []),
            ],
            focusedPaneId: nil,
            timestamp: 0
        )

        #expect(coordinator.preferredRightSideTargetPane(fromPanelId: leftPanel) == rightPane)
    }

    @Test func topRightBrowserReusePaneNilWhenUnsplit() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)
        host.panes = [PaneID()]
        #expect(coordinator.topRightBrowserReusePane() == nil)
    }

    @Test func topRightBrowserReusePanePicksRightmostTopPane() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let leftPane = PaneID(), rightPane = PaneID()
        host.panes = [leftPane, rightPane]
        host.tree = .split(
            ExternalSplitNode(
                id: UUID().uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: .pane(ExternalPaneNode(id: leftPane.id.uuidString, frame: PixelRect(x: 0, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil)),
                second: .pane(ExternalPaneNode(id: rightPane.id.uuidString, frame: PixelRect(x: 0.5, y: 0, width: 0.5, height: 1), tabs: [], selectedTabId: nil))
            )
        )

        #expect(coordinator.topRightBrowserReusePane() == rightPane)
    }

    @Test func setPreferredBrowserProfileIDClearsOnNilAndIgnoresUndefined() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let defined = UUID()
        let undefined = UUID()
        host.definedProfileIDs = [defined]

        // nil clears unconditionally.
        coordinator.setPreferredBrowserProfileID(nil)
        #expect(host.preferredWrites == [nil])
        #expect(host.preferredBrowserProfileID == nil)

        // An undefined id is ignored (no write).
        coordinator.setPreferredBrowserProfileID(undefined)
        #expect(host.preferredWrites == [nil])
        #expect(host.preferredBrowserProfileID == nil)

        // A defined id is stored.
        coordinator.setPreferredBrowserProfileID(defined)
        #expect(host.preferredWrites == [nil, defined])
        #expect(host.preferredBrowserProfileID == defined)
    }

    @Test func resolvedNewBrowserProfileIDFollowsTierOrder() {
        let host = FakeHost()
        let coordinator = SurfaceLifecycleCoordinator()
        coordinator.attach(host: host)

        let preferredArg = UUID()
        let sourceProfile = UUID()
        let stored = UUID()
        let lastUsed = UUID()
        let sourcePanel = UUID()
        host.effectiveLastUsedProfileID = lastUsed
        host.sourcePanelProfileID = [sourcePanel: sourceProfile]

        // Tier 1: explicit preferred arg when defined.
        host.definedProfileIDs = [preferredArg, sourceProfile, stored]
        host.preferredBrowserProfileID = stored
        #expect(
            coordinator.resolvedNewBrowserProfileID(
                preferredProfileID: preferredArg,
                sourcePanelId: sourcePanel
            ) == preferredArg
        )

        // Tier 2: source panel's profile when the preferred arg is undefined.
        host.definedProfileIDs = [sourceProfile, stored]
        #expect(
            coordinator.resolvedNewBrowserProfileID(
                preferredProfileID: preferredArg,
                sourcePanelId: sourcePanel
            ) == sourceProfile
        )

        // Tier 3: workspace stored preferred when arg + source are undefined.
        host.definedProfileIDs = [stored]
        #expect(
            coordinator.resolvedNewBrowserProfileID(
                preferredProfileID: preferredArg,
                sourcePanelId: sourcePanel
            ) == stored
        )

        // Tier 4: effective last-used fallback when nothing else is defined.
        host.definedProfileIDs = []
        #expect(
            coordinator.resolvedNewBrowserProfileID(
                preferredProfileID: preferredArg,
                sourcePanelId: sourcePanel
            ) == lastUsed
        )

        // No-arg call also lands on the fallback.
        #expect(coordinator.resolvedNewBrowserProfileID() == lastUsed)
    }
}

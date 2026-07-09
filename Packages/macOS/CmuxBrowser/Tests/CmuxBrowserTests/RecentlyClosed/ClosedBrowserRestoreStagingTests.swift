import Foundation
import Bonsplit
import Testing
@testable import CmuxBrowser

@MainActor
private final class StubStagingHost: ClosedBrowserRestoreStagingHosting {
    var stagingWorkspaceId = UUID()
    var stagingSuppressClosedPanelHistory = false
    var panelIdBySurface: [TabID: UUID] = [:]
    var browserPanelIds: Set<UUID> = []
    var tabIndexBySurface: [TabID: Int] = [:]
    var resolvedURLByPanel: [UUID: URL] = [:]
    var profileIDByPanel: [UUID: UUID] = [:]
    var temporaryURLs: Set<URL> = []
    var fallbackPlanByPane: [PaneID: ClosedBrowserRestoreFallbackPlan] = [:]

    func stagingPanelId(forSurfaceId surfaceId: TabID) -> UUID? {
        panelIdBySurface[surfaceId]
    }

    func stagingIsBrowserPanel(panelId: UUID) -> Bool {
        browserPanelIds.contains(panelId)
    }

    func stagingTabIndex(forSurfaceId surfaceId: TabID, inPane pane: PaneID) -> Int? {
        tabIndexBySurface[surfaceId]
    }

    func stagingResolvedURL(panelId: UUID) -> URL? {
        resolvedURLByPanel[panelId]
    }

    func stagingProfileID(panelId: UUID) -> UUID? {
        profileIDByPanel[panelId]
    }

    func stagingIsTemporaryHistoryURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return temporaryURLs.contains(url)
    }

    func stagingFallbackPlan(forPane pane: PaneID) -> ClosedBrowserRestoreFallbackPlan? {
        fallbackPlanByPane[pane]
    }
}

@MainActor
@Suite("ClosedBrowserRestoreStaging")
struct ClosedBrowserRestoreStagingTests {
    private func makeStagedHost() -> (StubStagingHost, ClosedBrowserRestoreStaging, Bonsplit.Tab, PaneID, UUID) {
        let host = StubStagingHost()
        let staging = ClosedBrowserRestoreStaging()
        staging.attach(host: host)
        let tab = Bonsplit.Tab(title: "Example")
        let pane = PaneID()
        let panelId = UUID()
        host.panelIdBySurface[tab.id] = panelId
        host.browserPanelIds.insert(panelId)
        host.tabIndexBySurface[tab.id] = 3
        host.resolvedURLByPanel[panelId] = URL(string: "https://example.com")!
        host.profileIDByPanel[panelId] = UUID()
        return (host, staging, tab, pane, panelId)
    }

    @Test func stagesSnapshotForBrowserPanelWithRestorableURL() {
        let (host, staging, tab, pane, panelId) = makeStagedHost()
        host.fallbackPlanByPane[pane] = ClosedBrowserRestoreFallbackPlan(
            orientation: .horizontal,
            insertFirst: true,
            anchorPaneId: pane.id
        )

        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        let snapshot = staging.consumeSnapshot(forTabId: tab.id)

        let resolved = try? #require(snapshot)
        #expect(resolved?.workspaceId == host.stagingWorkspaceId)
        #expect(resolved?.url == URL(string: "https://example.com"))
        #expect(resolved?.profileID == host.profileIDByPanel[panelId])
        #expect(resolved?.originalPaneId == pane.id)
        #expect(resolved?.originalTabIndex == 3)
        #expect(resolved?.fallbackSplitOrientation == .horizontal)
        #expect(resolved?.fallbackSplitInsertFirst == true)
        #expect(resolved?.fallbackAnchorPaneId == pane.id)
        // Consuming removes the entry.
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func defaultsFallbackInsertFirstToFalseWhenNoPlan() {
        // Retain `host`: the coordinator holds it weakly, so discarding the
        // binding deallocates it and every staging read no-ops.
        let (host, staging, tab, pane, _) = makeStagedHost()
        _ = host
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        let snapshot = staging.consumeSnapshot(forTabId: tab.id)
        #expect(snapshot?.fallbackSplitOrientation == nil)
        #expect(snapshot?.fallbackSplitInsertFirst == false)
        #expect(snapshot?.fallbackAnchorPaneId == nil)
    }

    @Test func suppressGateDropsPendingAndStagesNothing() {
        let (host, staging, tab, pane, _) = makeStagedHost()
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        host.stagingSuppressClosedPanelHistory = true
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func nonBrowserPanelStagesNothingAndDropsPending() {
        let (host, staging, tab, pane, panelId) = makeStagedHost()
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        host.browserPanelIds.remove(panelId)
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func missingPanelIdStagesNothing() {
        let (host, staging, tab, pane, _) = makeStagedHost()
        host.panelIdBySurface.removeValue(forKey: tab.id)
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func missingTabIndexStagesNothing() {
        let (host, staging, tab, pane, _) = makeStagedHost()
        host.tabIndexBySurface.removeValue(forKey: tab.id)
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func temporaryHistoryURLStagesNothingAndDropsPending() {
        let (host, staging, tab, pane, panelId) = makeStagedHost()
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        host.temporaryURLs.insert(host.resolvedURLByPanel[panelId]!)
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func clearSnapshotRemovesPending() {
        let (host, staging, tab, pane, _) = makeStagedHost()
        _ = host
        staging.stageSnapshotIfNeeded(for: tab, inPane: pane)
        staging.clearSnapshot(forTabId: tab.id)
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }

    @Test func stagesNothingWithoutHost() {
        let staging = ClosedBrowserRestoreStaging()
        let tab = Bonsplit.Tab(title: "Example")
        staging.stageSnapshotIfNeeded(for: tab, inPane: PaneID())
        #expect(staging.consumeSnapshot(forTabId: tab.id) == nil)
    }
}

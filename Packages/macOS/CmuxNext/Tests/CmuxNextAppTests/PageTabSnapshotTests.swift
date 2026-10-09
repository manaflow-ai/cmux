import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Observation
import os
import Testing

/// bd cx-5xsi: `snapshot.get` listed only the daemon's tabs, so an app-only
/// page tab (the App Store, a Settings page) that the strip showed was
/// missing, and a preflight that read the snapshot nearly reported a false
/// FAIL. Each app-only page tab is listed in its pane's `tabs` with kind
/// `page`, its page id, and whether the pane shows it.
@MainActor
@Suite(.serialized)
struct PageTabSnapshotTests {
    /// A main window with one mounted, focused pane and loaded settings.
    private func world(tree: DaemonTree? = nil) async throws -> (AppServices, WindowController, PaneController) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-page-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try tree ?? BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        let content = try #require(window.content)
        let paneID = LayoutPaneIDFixture.id(try #require(workspace.screens.first?.panes.first))
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        return (services, window, pane)
    }

    /// The `tabs` of the pane `paneKey` in `snapshot.get`'s topology.
    private func snapshotTabs(_ services: AppServices, pane paneKey: String) throws -> [CmuxNextSettings.JSONValue] {
        let json = ControlSnapshotPublisher.topology(services).json
        let panes = (json["workspaces"]?.arrayValue ?? []).flatMap { workspace in
            (workspace["screens"]?.arrayValue ?? []).flatMap { $0["panes"]?.arrayValue ?? [] }
        }
        let pane = try #require(panes.first { $0["key"]?.stringValue == paneKey || $0["id"]?.stringValue == paneKey })
        return pane["tabs"]?.arrayValue ?? []
    }

    @Test func snapshotListsAppOnlyPageTabsWithTheirKind() async throws {
        let (services, _, pane) = try await world()
        // Automation opens the App Store as a background tab; the user opens Settings (selected).
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation(origin: .cli)))
        #expect(services.registry.perform("openSettings", invocation: ActionInvocation()))
        let store = try #require(services.pages.keys(of: .appStore).first)
        let settings = try #require(services.pages.keys(of: .settings).first)
        await BrowserTabTests.settle { pane.stripModel.selectedID?.rawValue == settings }

        let tabs = try snapshotTabs(services, pane: pane.paneKey)
        let storeTab = try #require(tabs.first { $0["id"]?.stringValue == store }, "the App Store tab is listed")
        #expect(storeTab["kind"]?.stringValue == "page")
        #expect(storeTab["page"]?.stringValue == "app-store")
        #expect(storeTab["title"]?.stringValue == services.pages.provider(.appStore)?.title)
        #expect(storeTab["selected"]?.boolValue == false, "the App Store is a background tab")
        let settingsTab = try #require(tabs.first { $0["id"]?.stringValue == settings }, "the Settings tab is listed")
        #expect(settingsTab["kind"]?.stringValue == "page")
        #expect(settingsTab["page"]?.stringValue == "settings")
        #expect(settingsTab["selected"]?.boolValue == true)
        // The daemon's tab is still listed, and still counted alone.
        #expect(tabs.contains { $0["kind"]?.stringValue == "browser" })
        #expect(ControlSnapshotPublisher.topology(services).tabCount == 1)
    }

    /// The real app (tag apsf-v1): where the daemon holds page tabs
    /// (`page-tabs-v1`) the App Store is a store tab, which the snapshot
    /// listed as a conversation titled about:blank. It is kind `page` with
    /// its page id and the page's title.
    @Test func snapshotNamesAStorePageTabByItsPage() async throws {
        let json = #"""
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[{"kind":"browser","name":"cdp","surface":4,"dead":false,"browser_renderer":"daemon"},
        {"kind":"conversation","surface":9,"title":"about:blank","url":"about:blank","dead":false,"conversation":{"page":"app-store"}}]}]}]}]}
        """#
        let tree = try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
        let (services, _, pane) = try await world(tree: tree)
        let tabs = try snapshotTabs(services, pane: pane.paneKey)
        let storeTab = try #require(tabs.first { $0["surface"]?.stringValue == "9" })
        #expect(storeTab["kind"]?.stringValue == "page")
        #expect(storeTab["page"]?.stringValue == "app-store")
        #expect(storeTab["title"]?.stringValue == services.pages.provider(.appStore)?.title)
        #expect(tabs.first { $0["surface"]?.stringValue == "4" }?["kind"]?.stringValue == "browser")
        #expect(tabs.first { $0["surface"]?.stringValue == "4" }?["page"] == CmuxNextSettings.JSONValue.null)
    }

    /// Opening a page tab changes what the snapshot reads, so the publisher
    /// (which rebuilds on an observed change) publishes it without another trigger.
    @Test func openingAPageTabRepublishesTheSnapshot() async throws {
        let (services, _, _) = try await world()
        let changed = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking { ControlSnapshotPublisher.topology(services) } onChange: { changed.withLock { $0 = true } }
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation(origin: .cli)))
        #expect(!services.pages.keys(of: .appStore).isEmpty)
        #expect(changed.withLock { $0 }, "an app-only page tab opening invalidates the published snapshot")
    }
}

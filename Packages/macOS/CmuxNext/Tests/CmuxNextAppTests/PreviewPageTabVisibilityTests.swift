import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Preview page tabs are kept in daemon and local state while Labs is off, but leave the mounted
/// pane strip immediately. This exercises the pane's settings observation without a daemon event or
/// an explicit strip sync (the original regression only changed after a later pane refresh).
@MainActor @Suite(.serialized)
struct PreviewPageTabVisibilityTests {
    private static func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    @Test func previewPageTabsFollowLabsWithoutARefresh() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-preview-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "cmux.json")
        try Data(#"{"labs":{"previewFeatures":true}}"#.utf8).write(to: config)

        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: config,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()

        let terminal = TabSnapshot(surface: 1, title: "shell")
        var storedChangelog = TabSnapshot(surface: 2, kind: .conversation, title: "What's New")
        storedChangelog.conversation = ConversationTabRef(page: InternalPageID.changelog.rawValue)
        var storedAppStore = TabSnapshot(surface: 3, kind: .browser, title: "App Store")
        storedAppStore.app = AppTabRef(app: "cmux/app-store")
        let paneSnapshot = PaneSnapshot(id: 1, tabs: [terminal, storedChangelog, storedAppStore])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [paneSnapshot])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let state = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"preview-tabs"}"#.utf8)))
        let storedChangelogID = try #require(model.tabs.first(where: { $0.page == InternalPageID.changelog.rawValue })?.id)
        let storedAppStoreID = try #require(model.tabs.first(where: { $0.app?.app == "cmux/app-store" })?.id)
        state.selection.select(storedAppStoreID, in: model.id)

        let localChangelogID = services.pages.open(.changelog, in: model.id, of: services.daemon.store)
        let localAppStoreID = services.pages.open(.appStore, in: model.id, of: services.daemon.store)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let ids = { pane.stripModel.tabs.map(\.id.rawValue) }
        #expect(ids().contains(storedAppStoreID) && ids().contains(localAppStoreID))
        #expect(ids().contains(storedChangelogID) && ids().contains(localChangelogID))
        #expect(pane.stripModel.selectedID?.rawValue == storedAppStoreID)

        try await settings.set(.bool(false), at: ["labs", "previewFeatures"])
        await Self.until { !ids().contains(storedAppStoreID) && !ids().contains(localAppStoreID) &&
            pane.stripModel.selectedID?.rawValue != storedAppStoreID }
        #expect(!ids().contains(storedAppStoreID) && !ids().contains(localAppStoreID))
        // What's New is no Labs preview: an update's See What's New opens it with Labs off
        // (Leo 2026-10-29), so its tabs stay in the strip.
        #expect(ids().contains(storedChangelogID) && ids().contains(localChangelogID),
                "Labs off hid the What's New tab")
        #expect(model.tabs.contains { $0.id == storedAppStoreID } && model.tabs.contains { $0.id == storedChangelogID },
                "disabling Labs must not delete stored preview tabs")
        #expect(services.pages.tabIDs(in: model.id).contains(localAppStoreID) &&
            services.pages.tabIDs(in: model.id).contains(localChangelogID),
                "disabling Labs must not delete local preview tabs")
        let fallbackSelection = pane.stripModel.selectedID?.rawValue
        #expect(fallbackSelection != storedAppStoreID)

        try await settings.set(.bool(true), at: ["labs", "previewFeatures"])
        await Self.until { ids().contains(storedAppStoreID) && ids().contains(localAppStoreID) }
        #expect(ids().contains(storedAppStoreID) && ids().contains(localAppStoreID))
        #expect(pane.stripModel.selectedID?.rawValue == fallbackSelection,
                "re-enabling Labs must preserve the fallback selected while preview tabs were hidden")
    }
}

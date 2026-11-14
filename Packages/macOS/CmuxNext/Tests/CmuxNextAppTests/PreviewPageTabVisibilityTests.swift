import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The App Store is no Labs preview (Leo 2026-11-14: "yeah the whole point is for it to be usable"):
/// its tabs, stored and local, stay in the mounted pane strip when Labs is switched off, as What's
/// New's do, and the selection stays on them.
@MainActor @Suite(.serialized)
struct PreviewPageTabVisibilityTests {
    private static func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    @Test func appStoreAndWhatsNewTabsStayWhenLabsTurnsOff() async throws {
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
        await Self.until { settings.snapshot.previewFeatures == false }
        #expect(settings.snapshot.previewFeatures == false)
        #expect(ids().contains(storedAppStoreID) && ids().contains(localAppStoreID), "Labs off hid the App Store tab")
        #expect(ids().contains(storedChangelogID) && ids().contains(localChangelogID), "Labs off hid the What's New tab")
        #expect(pane.stripModel.selectedID?.rawValue == storedAppStoreID, "Labs off moved the selection off the App Store")
    }
}

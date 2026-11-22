import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import Foundation
import Testing
@testable import CmuxNextApp

/// App Store would not split: its tab lived only in this app, so the pane
/// under it held no store tab and refused to split or take other tabs.
/// Where the daemon holds page tabs (`page-tabs-v1`), a page opens as a store
/// conversation tab with a page source, like any other tab. It shows at once
/// as the store's provisional tab while `new-conversation-tab` is held.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PageStoreTabTests {
    private static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    @Test func aPageOpensAsAStoreTabWhereTheDaemonHoldsPageTabs() async throws {
        let daemon = try TopologyDaemon(extraCapabilities: [DaemonCapabilities.shared.pageTabs])
        let services = ActionBindingCoverageTests.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-page-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        let creations = HeldPageTabCreations()
        services.pages.createStoreTab = { pane, _, page, _ in try await creations.hold(pane, page) }
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            creations.release()
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
            daemon.stop()
        }

        try await Self.waitUntil { services.daemon.store.isLoaded && services.daemon.store.workspaces.count == 1 }
        let window = try #require(services.windows.openWindow(workspaces: [TopologyDaemon.firstKey]))
        services.windows.didActivate(window)
        try await Self.waitUntil { window.content?.panes.isEmpty == false }
        let pane = try #require(window.content?.panes.values.first)
        window.content?.layoutModel.focus(LayoutPaneIDFixture.id(pane.pane))

        #expect(services.registry.perform("openSettings", invocation: ActionInvocation()))

        func pageTabs() -> [TabModel] { pane.pane.tabs.filter { $0.page != nil } }
        try await Self.waitUntil("the Settings store tab shows") { pageTabs().count == 1 }
        let tab = try #require(pageTabs().first)
        #expect(tab.kind == .conversation)
        #expect(tab.page == InternalPageID.settings.rawValue)
        #expect(ProvisionalTab.isProvisional(tab.id), "the tab shows before the store answers")
        #expect(services.pages.tabIDs(in: pane.paneKey).isEmpty, "no app-only page tab")
        // The creation runs in a task: the tab showed before it started.
        try await Self.waitUntil("the store is asked for the tab") { creations.requests.count == 1 }
        #expect(creations.requests.map(\.page) == [InternalPageID.settings.rawValue])
        #expect(creations.requests.map(\.pane) == [pane.pane.handle])
        #expect(pane.stripModel.selectedID?.rawValue == tab.id, "a user run selects it")
        #expect(pane.focusPane.tabs.first { $0.id == tab.id }?.kind == .page)
        guard case .page(let view)? = pane.content(for: tab.id) else {
            Issue.record("a Settings store tab shows the Settings page")
            return
        }
        #expect(view.page == .settings)
        #expect(pane.snapshot().items.first { $0.id.rawValue == tab.id }?.title == SettingsDeepLink.pageTitle)

        // Again: the same tab, no second one.
        #expect(services.registry.perform("openSettings", invocation: ActionInvocation()))
        #expect(pageTabs().map(\.id) == [tab.id])
        #expect(creations.requests.count == 1)
    }
}

/// `new-conversation-tab` page calls held until the test ends; each then fails, which drops its tab.
@MainActor private final class HeldPageTabCreations {
    private(set) var requests: [(pane: PaneID, page: String)] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func hold(_ pane: PaneID, _ page: String) async throws -> (created: PageTabCreated, sequence: UInt64?) {
        requests.append((pane, page))
        if !released { await withCheckedContinuation { waiting.append($0) } }
        throw CancellationError()
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

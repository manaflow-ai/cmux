import AppKit
import CmuxNextBridge
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextTabs
import Testing

/// Lane 20: Settings opens as a tab (an internal page) in the focused pane
/// of the active window, not as a window of its own; every entry point
/// (Cmd-, palette, sidebar, CLI) runs `openSettings`. One tab per page per
/// window: opening it again selects the tab it has.
@MainActor
@Suite(.serialized)
struct InternalPageTabTests {
    @Test func pageIDsRoundTrip() {
        let key = LocalPageTab.makeKey(.debugSettings)
        #expect(key.hasPrefix("local-page:debug-settings:"))
        #expect(LocalPageTab.page(of: key) == .debugSettings)
        #expect(LocalPageTab.page(of: "local-agent:x") == nil)
        #expect(LocalPageTab.page(of: "local-page:") == nil)
    }

    /// A main window with one pane and loaded settings (scratch cmux.json).
    private func world() async throws -> (AppServices, WindowController, PaneController) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        let content = try #require(window.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        return (services, window, pane)
    }

    @Test func openSettingsOpensATabNotAWindow() async throws {
        let (services, window, pane) = try await world()
        let windowsBefore = NSApp.windows.count
        #expect(services.registry.perform("openSettings", invocation: ActionInvocation()))

        let keys = services.pages.keys(of: .settings)
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(pane.orderedIDs.map(\.rawValue).contains(key))
        await BrowserTabTests.settle { pane.stripModel.selectedID?.rawValue == key }
        #expect(pane.stripModel.selectedID?.rawValue == key, "a user run selects the Settings tab")
        #expect(services.settingsWindow.model != nil)
        #expect(services.settingsWindow.window === window.window, "Settings lives in the main window")
        #expect(NSApp.windows.count == windowsBefore, "no Settings window was made")
        #expect(pane.focusPane.tabs.first { $0.id == key }?.kind == .page)

        // Again: the same tab, no second one.
        services.registry.perform("openSettings", invocation: ActionInvocation())
        #expect(services.pages.keys(of: .settings) == [key])
    }

    @Test func automationOpensTheTabWithoutTakingTheSelection() async throws {
        let (services, _, pane) = try await world()
        let selected = pane.stripModel.selectedID
        services.registry.perform("openSettings", invocation: ActionInvocation(origin: .cli))
        let key = try #require(services.pages.keys(of: .settings).first)
        #expect(pane.orderedIDs.map(\.rawValue).contains(key))
        #expect(pane.stripModel.selectedID == selected)
    }

    @Test func closingTheTabDropsItsPage() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        _ = pane.content(for: key)
        #expect(services.pages.existingView(key) != nil)
        pane.close([StripTabID(key)])
        #expect(services.pages.keys(of: .settings).isEmpty)
        #expect(services.pages.existingView(key) == nil)
        #expect(!pane.orderedIDs.map(\.rawValue).contains(key))
        #expect(services.settingsWindow.model == nil, "the model goes once nothing shows it")
    }

    @Test func thePageViewIsTheTabContentAndTakesTheKeyboard() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        guard case .page(let view)? = pane.content(for: key) else {
            Issue.record("a Settings tab shows a page view")
            return
        }
        #expect(view.page == .settings)
        #expect(view.focusTarget.isDescendant(of: view))
        #expect(services.pages.stripItem(key).title == SettingsPane.title)
    }
}

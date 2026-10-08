import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// S22 (decisions.md, Lawrence 2026-10-02): the App Store and Settings open
/// as tabs, never as windows of their own, and Cmd-W in a secondary window
/// closes that window's content, never a tab of another main window.
@MainActor
@Suite(.serialized)
struct SecondaryWindowS22Tests {
    /// Two workspaces, one pane each.
    private static func twoWorkspaceTree() throws -> DaemonTree {
        func workspace(_ id: Int, _ key: String, screen: Int, pane: Int, surface: Int) -> String {
            """
            {"active":\(id == 1),"id":\(id),"key":"\(key)","name":"w\(id)","screens":[{"active":true,"id":\(screen),
            "layout":{"pane":\(pane),"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":\(pane),"name":null,
            "tabs":[{"kind":"browser","name":"cdp","surface":\(surface),"dead":false,"browser_renderer":"daemon"}]}]}]}
            """
        }
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[\(workspace(1, "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03", screen: 2, pane: 3, surface: 4)),
        \(workspace(5, "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b", screen: 6, pane: 7, surface: 8))]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    /// Bound services with loaded settings (scratch cmux.json) and no window.
    private static func services() async throws -> AppServices {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-s22-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        return services
    }

    /// A main window showing `workspace`, with its one pane mounted and focused.
    private static func mainWindow(_ services: AppServices, workspace: WorkspaceModel) async throws -> (WindowController, PaneController) {
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
        return (window, pane)
    }

    private static func commandW(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "w",
                                      charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    }

    private static func holds(_ pane: PaneController, _ key: String) -> Bool {
        pane.orderedIDs.map(\.rawValue).contains(key)
    }

    /// Two main windows, each with a Settings tab selected; the second
    /// window is key. Cmd-W (the key path, then the shared action) closes
    /// the second window's tab only; the first window keeps its tab.
    @Test func commandWInASecondMainWindowClosesOnlyThatWindowsTab() async throws {
        let services = try await Self.services()
        services.daemon.store.apply(snapshot: try Self.twoWorkspaceTree())
        let workspaces = services.daemon.store.workspaces
        try #require(workspaces.count == 2)
        let (first, firstPane) = try await Self.mainWindow(services, workspace: workspaces[0])
        let firstKey = try #require(services.pages.show(.settings, in: first, focus: true)?.key)
        let (second, secondPane) = try await Self.mainWindow(services, workspace: workspaces[1])
        let secondKey = try #require(services.pages.show(.settings, in: second, focus: true)?.key)
        #expect(firstKey != secondKey)
        await BrowserTabTests.settle { secondPane.stripModel.selectedID?.rawValue == secondKey }
        let secondWindow = try #require(second.window)
        services.keyWindowSource = { secondWindow }
        #expect(services.windows.active === second)

        #expect(services.keyRouter.interceptKeyDown(try Self.commandW(in: secondWindow), in: secondWindow))
        await BrowserTabTests.settle { !Self.holds(secondPane, secondKey) }
        #expect(!Self.holds(secondPane, secondKey), "Cmd-W closed the key window's tab")
        #expect(Self.holds(firstPane, firstKey), "the other main window's tab survived")
        #expect(services.pages.keys(of: .settings) == [firstKey])
        #expect(services.windows.controllers.count == 2)
    }

    /// With no main window, the App Store makes no window of its own (S22).
    /// A user's request waits, and the first window that opens shows the
    /// App Store as its top page, before any pane mounts (a window that comes
    /// back on Home mounts none).
    @Test func withNoWindowTheAppStoreWaitsForAWindowAndShowsThere() async throws {
        let services = try await Self.services()
        let windowsBefore = NSApp.windows.count
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation()))
        #expect(NSApp.windows.count == windowsBefore, "no App Store window was made")

        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.shownTopPage == .page(.appStore) }
        #expect(window.shownTopPage == .page(.appStore), "the waiting request shows the App Store")
    }

    /// Automation with no main window: no window either; the request opens
    /// the App Store as a background tab in the first window's pane.
    @Test func automationWithNoWindowOpensTheAppStoreTabInTheFirstWindow() async throws {
        let services = try await Self.services()
        let windowsBefore = NSApp.windows.count
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation(origin: .cli)))
        #expect(NSApp.windows.count == windowsBefore, "no App Store window was made")
        #expect(services.pages.keys(of: .appStore).isEmpty)

        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let (window, pane) = try await Self.mainWindow(services, workspace: workspace)
        let pageBefore = window.shownTopPage
        await BrowserTabTests.settle { !services.pages.keys(of: .appStore).isEmpty }
        let key = try #require(services.pages.keys(of: .appStore).first, "the waiting request opens the tab")
        #expect(Self.holds(pane, key))
        #expect(window.shownTopPage == pageBefore, "automation never changes the view")
    }

    /// The real app (s22w-v1): Close All Windows, then App Store brought a
    /// window back, but the request went to the closed window, which
    /// `WindowManager.active` still returned as the last active one. A
    /// closed window is never the active window; the App Store tab opens in
    /// the window that is open.
    @Test func aClosedWindowIsNeverTheActiveWindow() async throws {
        let services = try await Self.services()
        services.daemon.store.apply(snapshot: try Self.twoWorkspaceTree())
        let workspaces = services.daemon.store.workspaces
        try #require(workspaces.count == 2)
        let (closed, _) = try await Self.mainWindow(services, workspace: workspaces[0])
        services.keyWindowSource = { nil }
        closed.window?.close()
        #expect(!services.windows.controllers.contains { $0 === closed })
        #expect(services.windows.active !== closed, "a closed window is not the active window")

        // A window that opens behind (never key, never activated) holds the tab.
        let open = try #require(services.windows.openWindow(workspaces: [workspaces[1].id]))
        await BrowserTabTests.settle { open.content != nil }
        let content = try #require(open.content)
        let paneID = LayoutPaneIDFixture.id(try #require(workspaces[1].screens.first?.panes.first))
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        #expect(services.windows.active === open)
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation(origin: .cli)))
        await BrowserTabTests.settle { !services.pages.keys(of: .appStore).isEmpty }
        let key = try #require(services.pages.keys(of: .appStore).first)
        #expect(Self.holds(pane, key), "the App Store tab opened in the open window")
    }

    /// bd cx-beg1, the restored-app path: the user closes the only window,
    /// then runs App Store (palette or key, no window). The closed window
    /// comes back (`reopenOrCreateWindow`) and shows the App Store as its top
    /// page, the same view a user run gets with a window open; no tab is
    /// left behind. Automation in the same state reopens nothing it shows:
    /// its tab stays in the background (`automationWithNoWindow...`).
    @Test func aUserRunAfterCloseAllWindowsReopensTheWindowOnTheAppStore() async throws {
        let services = try await Self.services()
        services.windows.restoreWhenLoaded()
        services.daemon.store.apply(snapshot: try Self.twoWorkspaceTree())
        await BrowserTabTests.settle {
            !services.windows.registry.isLaunching && services.windows.restored && services.windows.controllers.first?.content != nil
        }
        let first = try #require(services.windows.controllers.first)
        let windowID = first.state.id
        services.keyWindowSource = { nil }
        first.window?.close()
        #expect(services.windows.controllers.isEmpty)
        #expect(services.registry.perform("appStore.show", invocation: ActionInvocation()))
        let reopened = try #require(services.windows.controllers.first, "the closed window came back")
        #expect(reopened.state.id == windowID)
        await BrowserTabTests.settle { reopened.shownTopPage == .page(.appStore) }
        #expect(reopened.shownTopPage == .page(.appStore), "the App Store shows and has the window")
        #expect(services.windows.active === reopened)
        #expect(services.pages.keys(of: .appStore).isEmpty, "no background App Store tab")
        #expect(!services.apps.isStoreWaiting)
        for controller in services.windows.controllers { controller.window?.close() }
    }
}

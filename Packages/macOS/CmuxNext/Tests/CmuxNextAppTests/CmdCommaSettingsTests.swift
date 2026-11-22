import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import Testing

/// Lawrence (hq-6d dogfood item 6): Cmd-, opens Settings from anywhere. The
/// key goes through the real dispatcher (`KeyRouter.interceptKeyDown`, the
/// hook `CmuxApplication.sendEvent` runs before any view); the dispatcher
/// consumes it (the focused surface never gets it) and runs the one shared
/// action, `openSettings`, which shows the one Settings surface where the
/// user can see it.
@MainActor
@Suite(.serialized)
struct CmdCommaSettingsTests {
    static let homeKey = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a01"
    static let codeKey = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a03"
    static let emptyKey = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a05"
    static let otherKey = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a07"

    /// A store with the home workspace (Home stands for it) and a user workspace, each with one pane.
    static func tree() throws -> DaemonTree {
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[
        {"active":true,"id":1,"key":"\(homeKey)","name":"Home","kind":"home",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[{"kind":"terminal","name":"","surface":4,"dead":false}]}]}]},
        {"active":false,"id":11,"key":"\(codeKey)","name":"code",
        "screens":[{"active":true,"id":12,"layout":{"pane":13,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":13,"name":null,
        "tabs":[{"kind":"terminal","name":"","surface":14,"dead":false}]}]}]},
        {"active":false,"id":21,"key":"\(emptyKey)","name":"empty","screens":[]},
        {"active":false,"id":31,"key":"\(otherKey)","name":"other",
        "screens":[{"active":true,"id":32,"layout":{"pane":33,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":33,"name":null,
        "tabs":[{"kind":"terminal","name":"","surface":34,"dead":false}]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    /// Services with loaded settings (scratch cmux.json) and one window that lists `workspaces`.
    static func world(workspaces: [String]) async throws -> (AppServices, WindowController) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-cmdcomma-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try tree())
        let window = try #require(services.windows.openWindow(workspaces: workspaces))
        services.windows.didActivate(window)
        return (services, window)
    }

    static func commandComma() throws -> NSEvent {
        try KeyInterceptionTests.key(",", keyCode: 43, [.command])
    }

    /// Whether `window` shows Settings: its Settings top page, or the
    /// selected tab of the shown workspace's focused pane is Settings.
    static func showsSettings(_ window: WindowController, _ services: AppServices) -> Bool {
        if window.shownTopPage == .page(.settings) { return true }
        guard window.shownTopPage == nil, let pane = window.content?.focusedPane ?? window.content?.panes.values.first,
              let selected = pane.stripModel.selectedID?.rawValue else { return false }
        return services.pages.keys(of: .settings).contains(selected)
            || pane.pane.tabs.contains { $0.id == selected && $0.page == InternalPageID.settings.rawValue }
    }

    /// Settings surfaces of every kind across the app (tabs and top pages).
    static func settingsSurfaceCount(_ services: AppServices) -> Int {
        let pageTabs = services.windows.controllers.flatMap { $0.content?.panes.values.map { $0 } ?? [] }
            .flatMap(\.pane.tabs).filter { $0.page == InternalPageID.settings.rawValue }.count
        let topPages = services.windows.controllers.filter { $0.topPages.views[.page(.settings)] != nil }.count
        return services.pages.keys(of: .settings).count + pageTabs + topPages
    }

    /// nx-coordinator builder-handoff: "Cmd-, while Home is shown does
    /// nothing visible". Home stands for the window's home workspace, so
    /// leaving the page for the tab showed Home again and the Settings tab
    /// (or a request that waited for a pane) stayed out of sight.
    @Test func commandCommaOnHomeShowsSettings() async throws {
        let (services, window) = try await Self.world(workspaces: [Self.homeKey, Self.codeKey])
        await BrowserTabTests.settle { window.shownTopPage == .home }
        #expect(window.shownTopPage == .home, "the window opens on Home in place of its home workspace")
        let shell = try #require(window.window)

        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell), "the dispatcher consumes Cmd-,")
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(Self.showsSettings(window, services), "Settings is visible in the window")
        #expect(Self.settingsSurfaceCount(services) == 1)

        // Again: the same Settings, no second one.
        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { false }
        #expect(Self.showsSettings(window, services))
        #expect(Self.settingsSurfaceCount(services) == 1, "Cmd-, twice opens Settings once")
    }

    /// The same key in a workspace (a terminal has the keyboard) opens the Settings tab there, once.
    @Test func commandCommaInAWorkspaceShowsTheSettingsTabOnce() async throws {
        let (services, window) = try await Self.world(workspaces: [Self.codeKey, Self.homeKey])
        await BrowserTabTests.settle { window.content?.panes.isEmpty == false }
        let shell = try #require(window.window)
        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(Self.showsSettings(window, services))
        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { false }
        #expect(Self.settingsSurfaceCount(services) == 1)
    }

    /// nxdog70-v1 (builder): a fresh launch with only an empty workspace
    /// showed no Settings on Cmd-,; the tab appeared only once a pane
    /// existed. Settings needs no pane to show.
    @Test func commandCommaInAWorkspaceWithNoPaneShowsSettings() async throws {
        let (services, window) = try await Self.world(workspaces: [Self.emptyKey])
        await BrowserTabTests.settle { window.content != nil }
        #expect(window.content?.panes.isEmpty == true, "the shown workspace has no pane")
        let shell = try #require(window.window)
        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(Self.showsSettings(window, services), "Settings is visible with zero panes")
        #expect(Self.settingsSurfaceCount(services) == 1)
    }

    /// No window is key (the app is active with its window in the back, or
    /// an automation launch): the dispatcher has no window to decide in and
    /// passes the key on; the main menu's Settings item (the same action)
    /// takes it and Settings shows in the active window, once, even on Home.
    @Test func withNoKeyWindowTheMenuItemShowsSettingsOnce() async throws {
        let (services, window) = try await Self.world(workspaces: [Self.homeKey, Self.codeKey])
        await BrowserTabTests.settle { window.shownTopPage == .home }
        let menu = MainMenu.make(registry: services.registry)
        let event = try Self.commandComma()
        #expect(!services.keyRouter.interceptKeyDown(event, in: nil), "no key window: the dispatcher passes the key on")
        let registry = services.registry
        let previous = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        defer { registry.isDispatchingKeyDown = previous }
        #expect(services.keyRouter.dispatchingSynthetic(event) { menu.performKeyEquivalent(with: event) }, "the Settings menu item takes Cmd-,")
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(Self.showsSettings(window, services))
        #expect(services.keyRouter.dispatchingSynthetic(event) { menu.performKeyEquivalent(with: event) })
        await BrowserTabTests.settle { false }
        #expect(Self.settingsSurfaceCount(services) == 1, "the menu item twice opens Settings once")
    }

    /// Every focus context: the dispatcher takes Cmd-, for `openSettings`
    /// (system tier) in a content window, whatever has the keyboard
    /// (terminal, page, Chromium page window, address bar, find bar, browser
    /// focus mode, agent composer, Home, Settings, sidebar and its field, an
    /// empty pane), so the surface never gets the key. A panel over the
    /// window (palette, sheet) has its own keys: the dispatcher passes the
    /// key on and the menu gate lets the Settings menu item run it.
    @Test func commandCommaRunsOpenSettingsInEveryFocusContext() throws {
        let services = KeyOwnershipMatrixTests.services()
        let event = try Self.commandComma()
        var failures: [String] = []
        for surface in KeyOwnershipMatrixTests.surfaces {
            let owner = KeyOwnershipMatrixTests.owner(services, event, surface)
            let expected: KeyOwner = surface.window == .content ? .action("openSettings") : .panel
            if owner != expected { failures.append("\(surface.name): \(owner) != \(expected)") }
            if surface.window != .content, !KeyRouter.allowsMenu(services.registry.keyTier(for: "openSettings"), id: "openSettings",
                                                                  focus: surface.focus, keyWindow: surface.window) {
                failures.append("\(surface.name): the menu gate refuses Settings")
            }
        }
        var sheet = KeyOwnershipMatrixTests.terminal
        sheet.overlays = [.sheet]
        if !KeyRouter.allowsMenu(services.registry.keyTier(for: "openSettings"), id: "openSettings", focus: sheet, keyWindow: .textPanel) {
            failures.append("sheet: the menu gate refuses Settings")
        }
        if !KeyRouter.allowsMenu(services.registry.keyTier(for: "openSettings"), id: "openSettings", focus: sheet, keyWindow: .other) {
            failures.append("no cmux key window: the menu gate refuses Settings")
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// nxdog77-v1 live check: a window had a Settings tab in workspace W3,
    /// and Cmd-, in workspace-12 opened a second Settings tab. The window's
    /// one Settings tab comes back instead: its workspace is shown and the
    /// tab selected.
    @Test func commandCommaInAnotherWorkspaceShowsTheExistingSettingsTab() async throws {
        let (services, window) = try await Self.world(workspaces: [Self.codeKey, Self.otherKey])
        await BrowserTabTests.settle { window.content?.panes.isEmpty == false }
        let shell = try #require(window.window)
        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(window.state.workspaceID == Self.codeKey)
        #expect(Self.settingsSurfaceCount(services) == 1)

        services.windows.select(Self.otherKey, in: window.state)
        window.showWorkspace(requested: Self.otherKey)
        await BrowserTabTests.settle { window.content?.workspace.id == Self.otherKey && window.content?.panes.isEmpty == false }
        #expect(window.content?.workspace.id == Self.otherKey)
        #expect(!Self.showsSettings(window, services))

        #expect(services.keyRouter.interceptKeyDown(try Self.commandComma(), in: shell))
        await BrowserTabTests.settle { Self.showsSettings(window, services) }
        #expect(Self.showsSettings(window, services), "Settings is in front again")
        #expect(window.state.workspaceID == Self.codeKey, "the workspace that holds the Settings tab is shown")
        #expect(Self.settingsSurfaceCount(services) == 1, "no second Settings tab")
    }
}

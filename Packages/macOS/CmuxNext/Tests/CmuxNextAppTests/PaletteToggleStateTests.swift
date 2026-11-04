import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextLayout
@testable import CmuxNextSettings
import Foundation
import Testing

// CmuxNextLayout has its own PaneID; the daemon tree takes the daemon's.
private typealias DaemonPaneID = CmuxNextDaemon.PaneID

/// The palette's on/off rows say whether they are on now (the user, 2026-11-03: "'toggle' options
/// are very confusing, since we don't know the current state"). Each toggle bound by
/// `AppActions.bind` reports the state of the key window or focused pane it would flip, and the
/// report follows the real state, on and off.
@MainActor @Suite(.serialized)
struct PaletteToggleStateTests {
    private static func state(_ id: ActionID, _ services: AppServices) -> Bool? {
        services.registry.action(for: id)?.paletteState?()
    }

    private struct Window {
        let services: AppServices
        let controller: WindowController
        let close: () -> Void
    }

    /// The app with one window and no daemon panes (window-level toggles).
    private static func window() throws -> Window {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-palette-toggle-state-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["palette-toggle-ws"]))
        return Window(services: services, controller: controller, close: {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @Test func leftSidebarRowFollowsTheSidebar() throws {
        let w = try Self.window()
        defer { w.close() }
        let model = w.controller.sidebar.model
        #expect(Self.state("toggleSidebar", w.services) == !model.isHidden)
        for _ in 0..<2 {
            let wasHidden = model.isHidden
            #expect(w.services.registry.perform("toggleSidebar", invocation: ActionInvocation(origin: .user)))
            #expect(model.isHidden != wasHidden)
            #expect(Self.state("toggleSidebar", w.services) == !model.isHidden, "the row does not say whether the sidebar shows")
        }
    }

    @Test func rightSidebarRowFollowsTheRightSidebar() throws {
        let w = try Self.window()
        defer { w.close() }
        #expect(Self.state("toggleRightSidebar", w.services) == false)
        #expect(w.services.registry.perform("toggleRightSidebar"))
        #expect(w.controller.rightSidebar.isVisible)
        #expect(Self.state("toggleRightSidebar", w.services) == true)
        #expect(w.services.registry.perform("toggleRightSidebar"))
        #expect(Self.state("toggleRightSidebar", w.services) == false)
    }

    /// Entering full screen is an animated AppKit transition a test window cannot make; the row
    /// reads the window's own style mask, off here.
    @Test func fullScreenRowIsOffForAWindowedWindow() throws {
        let w = try Self.window()
        defer { w.close() }
        #expect(w.controller.window?.styleMask.contains(.fullScreen) == false)
        #expect(Self.state("toggleFullScreen", w.services) == false)
    }

    @Test func notificationBannersRowFollowsTheDesktopMode() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.notifications.preferences.desktop = .never
        #expect(Self.state("notifications.toggleBanners", services) == false)
        services.notifications.preferences.desktop = .unlessFocused
        #expect(Self.state("notifications.toggleBanners", services) == true)
    }

    @Test func columnScrollbarRowFollowsTheSetting() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let design = DesignSettings.shared, before = design.stripScrollbar
        defer { design.stripScrollbar = before }
        design.stripScrollbar = .off
        #expect(Self.state("layout.toggleStripScrollbar", services) == false)
        design.stripScrollbar = .system
        #expect(Self.state("layout.toggleStripScrollbar", services) == true)
        design.stripScrollbar = .always
        #expect(Self.state("layout.toggleStripScrollbar", services) == true)
    }

    @Test func matchTerminalBackgroundRowFollowsTheSidebarSurface() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-palette-match-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        let id: ActionID = "palette.toggleMatchTerminalBackground"
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            // test-wait: the toggle writes cmux.json in a task; the snapshot reloads after it.
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        // The default matches the terminal ("same").
        #expect(Self.state(id, services) == true)
        #expect(services.registry.perform(id, invocation: ActionInvocation()))
        await until { SidebarSurfaceSetting.effective(in: settings.snapshot) == .separate }
        #expect(Self.state(id, services) == false)
        #expect(services.registry.perform(id, invocation: ActionInvocation()))
        await until { SidebarSurfaceSetting.effective(in: settings.snapshot) == .same }
        #expect(Self.state(id, services) == true)
    }

    @Test func dockRowsFollowTheKeyWindowsDocks() throws {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register([LayoutTunables.dockedWorkspaces.descriptor])
        let key = LayoutTunables.dockedWorkspaces.key, previous = store.override(key)
        defer { store.set(key, previous) }
        store.set(key, .bool(true))
        let w = try Self.window()
        defer { w.close() }
        let ids: [DockEdge: ActionID] = [.left: "window.toggleDockLeft", .right: "window.toggleDockRight",
                                         .top: "window.toggleDockTop", .bottom: "window.toggleDockBottom"]
        for id in ids.values { #expect(Self.state(id, w.services) == false, "\(id) is on with no dock") }
        w.controller.state.docks.dock("docked-ws", at: .left)
        #expect(Self.state("window.toggleDockLeft", w.services) == true)
        #expect(Self.state("window.toggleDockRight", w.services) == false)
        _ = w.controller.state.docks.toggle(.left)
        #expect(Self.state("window.toggleDockLeft", w.services) == false, "a hidden dock reads as on")
        _ = w.controller.state.docks.toggle(.left)
        #expect(Self.state("window.toggleDockLeft", w.services) == true)
        // Off (Debug Settings), the docks never show and the toggles refuse.
        store.set(key, .bool(false))
        #expect(Self.state("window.toggleDockLeft", w.services) == false)
    }

    // MARK: Focused pane

    private static func tree(zoomed: DaemonPaneID? = nil) -> DaemonTree {
        let first = PaneSnapshot(id: DaemonPaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: DaemonPaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: CmuxNextDaemon.ScreenID(rawValue: 1), zoomedPane: zoomed, layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "toggle-ws"), name: "toggle", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "toggle-ws"), index: 0)])
        return tree
    }

    private struct Panes {
        let services: AppServices
        let controller: WindowController
        let content: WorkspaceContentController
        /// The focused pane (daemon pane 1).
        let focused: PaneController
        let other: PaneController
    }

    /// The app with one window showing a two-pane split, the left pane focused.
    private static func panes() async throws -> Panes {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["toggle-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        // test-wait: the window shows the workspace's panes once its content controller builds them.
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        let first = try #require(content.panes.values.first { $0.pane.handle == DaemonPaneID(rawValue: 1) })
        let second = try #require(content.panes.values.first { $0.pane.handle == DaemonPaneID(rawValue: 2) })
        PaneHandlers.focus(first.layoutPaneID, in: content)
        try #require(content.focusedPane === first, "the left pane never took the focus")
        return Panes(services: services, controller: controller, content: content, focused: first, other: second)
    }

    @Test func paneZoomRowFollowsTheFocusedPanesZoom() async throws {
        let p = try await Self.panes()
        defer { p.controller.teardown(); p.controller.window?.close() }
        let store = p.services.machines.local.store
        #expect(Self.state("toggleSplitZoom", p.services) == false)
        store.apply(snapshot: Self.tree(zoomed: DaemonPaneID(rawValue: 1)))
        #expect(Self.state("toggleSplitZoom", p.services) == true, "the row does not say the focused pane is zoomed")
        store.apply(snapshot: Self.tree(zoomed: DaemonPaneID(rawValue: 2)))
        #expect(Self.state("toggleSplitZoom", p.services) == false, "another pane's zoom reads as the focused pane's")
        store.apply(snapshot: Self.tree())
        #expect(Self.state("toggleSplitZoom", p.services) == false)
    }

    @Test func canvasLayoutRowFollowsTheFocusedScreen() async throws {
        let p = try await Self.panes()
        defer { p.controller.teardown(); p.controller.window?.close() }
        #expect(Self.state("toggleCanvasLayout", p.services) == false)
        #expect(p.services.registry.perform("toggleCanvasLayout", invocation: ActionInvocation(origin: .user)))
        #expect(p.content.layoutModel.canvasScreenID(containing: p.focused.layoutPaneID) != nil)
        #expect(Self.state("toggleCanvasLayout", p.services) == true)
        #expect(p.services.registry.perform("toggleCanvasLayout", invocation: ActionInvocation(origin: .user)))
        #expect(Self.state("toggleCanvasLayout", p.services) == false)
    }

    @Test func fullWidthTabRowFollowsTheFocusedPane() async throws {
        let p = try await Self.panes()
        defer { p.controller.teardown(); p.controller.window?.close() }
        let modes = p.services.paneFullWidthTabs
        defer { for pane in [p.focused, p.other] where modes.contains(pane.paneKey) { modes.toggle(pane.paneKey) } }
        #expect(Self.state("palette.toggleFullWidthTab", p.services) == false)
        #expect(p.services.registry.perform("palette.toggleFullWidthTab", invocation: ActionInvocation(origin: .user)))
        #expect(modes.contains(p.focused.paneKey))
        #expect(Self.state("palette.toggleFullWidthTab", p.services) == true)
        // Another pane's mode is not the focused pane's.
        #expect(p.services.registry.perform("palette.toggleFullWidthTab", invocation: ActionInvocation(origin: .user)))
        modes.toggle(p.other.paneKey)
        #expect(Self.state("palette.toggleFullWidthTab", p.services) == false)
    }

    @Test func textBoxAndCopyModeRowsFollowTheFocusedTerminal() async throws {
        let p = try await Self.panes()
        defer { p.controller.teardown(); p.controller.window?.close() }
        #expect(Self.state("palette.terminalToggleTextBoxInput", p.services) == false)
        #expect(Self.state("toggleTerminalCopyMode", p.services) == false)
        // The CLI's run: the box shows without taking the keyboard.
        #expect(p.services.registry.perform("palette.terminalToggleTextBoxInput", invocation: ActionInvocation(origin: .cli)))
        guard case .terminal(let entry)? = p.focused.currentContent else {
            Issue.record("the focused pane shows no terminal")
            return
        }
        #expect(entry.textBox?.model.isVisible == true)
        #expect(Self.state("palette.terminalToggleTextBoxInput", p.services) == true, "the row does not say the TextBox shows")
        #expect(p.services.registry.perform("palette.terminalToggleTextBoxInput", invocation: ActionInvocation(origin: .cli)))
        #expect(Self.state("palette.terminalToggleTextBoxInput", p.services) == false)
        #expect(Self.state("toggleTerminalCopyMode", p.services) == entry.session.surfaceView.isCopyModeActive)
    }
}

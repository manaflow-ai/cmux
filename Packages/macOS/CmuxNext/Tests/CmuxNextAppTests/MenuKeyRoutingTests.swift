import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// A main-menu key equivalent takes a key only where the key router lets it (hq#2015 C11).
/// - In a terminal, a chord the dispatcher already gave to the terminal (the user's Ghostty
///   keybind won it) runs that keybind: the main menu never takes it first, whether its item
///   would run (Quit, a system action) or is refused (Toggle Sidebar).
/// - A panel or sheet over a cmux window has the keyboard: a navigation item on the same chord
///   (Cmd-B, Toggle Sidebar) does not act on the window behind it.
@MainActor @Suite(.serialized) struct MenuKeyRoutingTests {
    @MainActor private final class Probe {
        var runs = 0
    }

    private static func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, at timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    /// A menu bar holding the registry's items for `ids`, as `MainMenu` builds them.
    private static func menu(_ registry: ActionRegistry, items ids: [ActionID]) -> NSMenu {
        let bar = NSMenu()
        let holder = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Test")
        for id in ids { if let item = registry.makeMenuItem(for: id) { submenu.addItem(item) } }
        holder.submenu = submenu
        bar.addItem(holder)
        return bar
    }

    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The user's Ghostty config binds Cmd-Q and Cmd-B to text; cmux has Quit (system tier) and
    /// Toggle Sidebar (navigation tier) on those chords. The dispatcher delivered both keys to the
    /// terminal, so the Ghostty keybinds run and neither menu item does.
    @Test func aGhosttyKeybindTheDispatcherDeliveredWinsOverTheMenuItemOnItsChord() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        let quit = Probe(), sidebar = Probe()
        registry.unbind("quit")
        registry.bind("quit") { quit.runs += 1 }
        registry.unbind("toggleSidebar")
        registry.bind("toggleSidebar") { sidebar.runs += 1 }
        let previousDispatching = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        let previousClaim = TerminalKeyEquivalent.menuMayClaim
        // As `TerminalHooks` installs it at launch.
        TerminalKeyEquivalent.menuMayClaim = { [weak services] in services?.keyRouter.menuMayClaim($0) ?? true }
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = Self.menu(registry, items: ["quit", "toggleSidebar"])

        let text = "keybind = cmd+q=text:c11q\nkeybind = cmd+b=text:c11b\n"
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(config)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.setTheme(GhosttyThemeConfig(config: config, themeName: "cmux-next-test", colors: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            NSApp.mainMenu = previousMenu
            TerminalKeyEquivalent.menuMayClaim = previousClaim
            registry.isDispatchingKeyDown = previousDispatching
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        try #require(window.makeFirstResponder(session.surfaceView), "the terminal never took the keyboard")
        func written() -> String { String(decoding: io.writes.reduce(Data(), +), as: UTF8.self) }

        // The menu items are live: a Cmd-Q the dispatcher never saw (a synthetic key) is Quit's.
        let synthetic = try Self.key("q", keyCode: 12, flags: [.command], at: 100)
        #expect(services.keyRouter.dispatchingSynthetic(synthetic) { session.surfaceView.performKeyEquivalent(with: synthetic) })
        #expect(quit.runs == 1, "the menu's Quit did not take an undecided Cmd-Q")

        // Cmd-Q, Quit is a system item the menu gate would allow: the Ghostty keybind runs.
        let quitKey = try Self.key("q", keyCode: 12, flags: [.command], at: 200)
        services.keyRouter.decided.add(quitKey) // the dispatcher delivered it to the terminal
        #expect(services.keyRouter.dispatchingSynthetic(quitKey) { session.surfaceView.performKeyEquivalent(with: quitKey) })
        await Self.wait(within: .seconds(5)) { written().contains("c11q") }
        #expect(quit.runs == 1, "the menu's Quit took a Cmd-Q the user's Ghostty keybind won")
        #expect(written().contains("c11q"), "the Ghostty keybind on Cmd-Q never ran (wrote \(written().debugDescription))")

        // Cmd-B, Toggle Sidebar is refused after the dispatcher decided the key: the refused
        // item does not consume it, the Ghostty keybind runs.
        let sidebarKey = try Self.key("b", keyCode: 11, flags: [.command], at: 300)
        services.keyRouter.decided.add(sidebarKey)
        #expect(services.keyRouter.dispatchingSynthetic(sidebarKey) { session.surfaceView.performKeyEquivalent(with: sidebarKey) })
        await Self.wait(within: .seconds(5)) { written().contains("c11b") }
        #expect(sidebar.runs == 0, "Toggle Sidebar took a Cmd-B the user's Ghostty keybind won")
        #expect(written().contains("c11b"), "the Ghostty keybind on Cmd-B never ran (wrote \(written().debugDescription))")
    }

    /// A panel over a cmux window is key (as the palette or a sheet is): Cmd-B reaches the main
    /// menu after the panel, and Toggle Sidebar (navigation tier) does not act on the window
    /// behind it. With the window itself key, the same chord toggles its sidebar.
    @Test func aNavigationMenuItemDoesNotActOnTheWindowBehindAKeyPanel() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let registry = services.registry
        let sidebar = Probe()
        registry.unbind("toggleSidebar")
        registry.bind("toggleSidebar") { sidebar.runs += 1 }
        try #require(registry.keyTier(for: "toggleSidebar") == .navigation)
        let previousDispatching = registry.isDispatchingKeyDown
        registry.isDispatchingKeyDown = { true }
        let menu = Self.menu(registry, items: ["toggleSidebar"])
        let controller = try #require(services.windows.openWindow(workspaces: ["c11-panel-workspace"]))
        let shell = try #require(controller.window)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        shell.addChildWindow(panel, ordered: .above)
        let previousKey = services.keyWindowSource
        defer {
            services.keyWindowSource = previousKey
            registry.isDispatchingKeyDown = previousDispatching
            shell.removeChildWindow(panel)
            panel.close()
            for controller in services.windows.controllers { controller.window?.close() }
        }

        // The cmux window is key: Cmd-B is Toggle Sidebar.
        services.keyWindowSource = { shell }
        let inWindow = try Self.key("b", keyCode: 11, flags: [.command], at: 400)
        _ = services.keyRouter.dispatchingSynthetic(inWindow) { menu.performKeyEquivalent(with: inWindow) }
        #expect(sidebar.runs == 1, "Cmd-B in the window did not toggle its sidebar")

        // The panel over it is key: the window's sidebar stays.
        services.keyWindowSource = { panel }
        let inPanel = try Self.key("b", keyCode: 11, flags: [.command], at: 500)
        _ = services.keyRouter.dispatchingSynthetic(inPanel) { menu.performKeyEquivalent(with: inPanel) }
        #expect(sidebar.runs == 1, "Cmd-B in a panel over the window toggled the window's sidebar")
    }
}

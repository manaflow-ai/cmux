import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTerminal
import Foundation
import CmuxNextTestSupport
import GhosttyNextKit
import Testing
import CmuxNextFocus
import CmuxNextFocusUI

/// Which of a terminal's Command chords the main menu takes before Ghostty (hq#2015 C11), through
/// the real path: the key router decides the key-down (`interceptKeyDown`), then the terminal
/// view gets it as a key equivalent.
/// - A chord the user's Ghostty config binds (cmux has a default on it: Quit on Cmd-Q, Toggle
///   Sidebar on Cmd-B) runs that keybind; no menu item takes it first.
/// - With the default config nothing changes: Cmd-Z and Cmd-Shift-Z are Edit > Undo and Redo,
///   Cmd-A is Select All (the menu takes them, not Ghostty), and Cmd-Q is Quit.
@MainActor @Suite(.serialized, .closesItsWindows) struct MenuKeyRoutingTests {
    @MainActor private final class Probe: NSObject {
        var runs: [String] = []
        @objc func undo(_ sender: Any?) { runs.append("undo") }
        @objc func redo(_ sender: Any?) { runs.append("redo") }
        @objc func selectAll(_ sender: Any?) { runs.append("selectAll") }
        func count(_ name: String) -> Int { runs.filter { $0 == name }.count }
    }

    /// The app on a cmux window whose focused pane is a terminal tab, the Ghostty config made of
    /// `userConfig` loaded into the router's binding table, and a live terminal surface with that
    /// config, first responder of its window.
    private struct Harness {
        let services: AppServices
        let shell: NSWindow
        let session: TerminalSession
        let io: ScriptedTerminalIO
        let terminalWindow: NSWindow

        var written: String { String(decoding: io.writes.reduce(Data(), +), as: UTF8.self) }

        func close() {
            io.finish()
            terminalWindow.close()
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    private static func harness(userConfig: String) throws -> Harness {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["c11-workspace"]))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "c11-workspace", panes: [
            .init(id: "c11-pane", tabs: [.init(id: "c11-tab", kind: .terminal)], selected: "c11-tab"),
        ])))
        controller.focus.send(.focusPane("c11-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "c11-pane", tab: "c11-tab"),
                     "the window's focus is \(controller.focus.state.resolved), not its terminal")

        // The Ghostty config as the app loads it: cmux's keybind defaults, then the user's lines.
        let user = try #require(ghostty_config_new())
        GhosttyRuntime.loadKeybindDefaults(into: user)
        userConfig.withCString { ghostty_config_load_string(user, $0, UInt(userConfig.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(user)
        let defaults = try #require(GhosttyKeyClaims.defaultsConfig())
        defer { ghostty_config_free(defaults) }
        // The keys cmux has defaults on that the user's lines claim (`GhosttyKeybindSync`).
        let keyNames = KeyCodeLayout.currentKeyNames()
        let probes = GhosttyKeyBindingLayer.defaultKeys(RegistryKeyBindings(services.registry).table).compactMap { key in
            GhosttyKeyBindingLayer.probe(for: key, keyNames: keyNames).map { (key, $0) }
        }
        let claimed = GhosttyKeyClaims.claimed(probes.map(\.1), user: user, texts: [userConfig])
        let claims = zip(probes, claimed).compactMap { probe, isClaimed in isClaimed ? probe.0 : nil }
        services.keyRouter.loadGhosttyKeybinds(GhosttyHostKeybind.read(from: user), defaults: GhosttyHostKeybind.read(from: defaults),
                                               claims: claims, keyNames: keyNames)

        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        // The theme config owns `user` (and frees it).
        session.setTheme(GhosttyThemeConfig(config: user, themeName: "cmux-next-test", colors: nil))
        let terminalWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        terminalWindow.isReleasedWhenClosed = false
        terminalWindow.contentView = session.view
        session.view.layoutSubtreeIfNeeded()
        try #require(terminalWindow.makeFirstResponder(session.surfaceView), "the terminal never took the keyboard")
        return Harness(services: services, shell: shell, session: session, io: io, terminalWindow: terminalWindow)
    }

    private static var timestamp: TimeInterval = 1000

    /// A Command key-down as AppKit delivers it: the router decides it in `sendEvent`; a key it
    /// did not consume reaches the terminal view as a key equivalent. Whether something took it.
    private static func press(_ characters: String, keyCode: UInt16, shift: Bool = false, in harness: Harness) throws -> Bool {
        timestamp += 1
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                                                  timestamp: timestamp, windowNumber: harness.shell.windowNumber, context: nil,
                                                  characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        let router = harness.services.keyRouter
        return router.dispatchingSynthetic(event) {
            router.interceptKeyDown(event, in: harness.shell) || harness.session.surfaceView.performKeyEquivalent(with: event)
        }
    }

    /// The menu bar and the app's terminal hooks swapped in for `body` (no suspension inside), then
    /// restored. The registry's key-down reading is the app's own: `press` dispatches through the
    /// router's dispatch context, as `sendEvent` does.
    private static func withMenu(_ menu: NSMenu, _ harness: Harness, _ body: () throws -> Void) rethrows {
        let previousMenu = NSApp.mainMenu
        let previousClaim = TerminalKeyEquivalent.menuMayClaim, previousAppAction = GhosttyRuntime.shared.appActionHandler
        let previousOwns = TerminalKeyEquivalent.userKeybindOwns, previousSend = TerminalKeyEquivalent.sendToProgram
        NSApp.mainMenu = menu
        TerminalHooks(services: harness.services).install()
        defer {
            NSApp.mainMenu = previousMenu
            TerminalKeyEquivalent.menuMayClaim = previousClaim
            TerminalKeyEquivalent.userKeybindOwns = previousOwns
            TerminalKeyEquivalent.sendToProgram = previousSend
            GhosttyRuntime.shared.appActionHandler = previousAppAction
        }
        try body()
    }

    private static func menuBar(_ items: [NSMenuItem]) -> NSMenu {
        let bar = NSMenu(), holder = NSMenuItem(title: "Test", action: nil, keyEquivalent: ""), submenu = NSMenu(title: "Test")
        for item in items { submenu.addItem(item) }
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

    /// The user's Ghostty config binds Cmd-Shift-N and Cmd-B to text; cmux's defaults there are New
    /// Window (system tier) and Toggle Sidebar (navigation tier). Both keys run the user's keybinds.
    @Test func theUsersGhosttyKeybindWinsOverTheMenuItemOnItsChord() async throws {
        let harness = try Self.harness(userConfig: "keybind = cmd+shift+n=text:c11n\nkeybind = cmd+b=text:c11b\n")
        defer { harness.close() }
        let registry = harness.services.registry
        let actions = Probe()
        // Ghostty binds neither chord itself, so the config's lines claim them from cmux's defaults.
        let claims = registry.keyBindingLayers.ghosttyClaims
        try #require(claims.contains(Shortcut("n", modifiers: [.command, .shift])), "Cmd-Shift-N is not the user's: \(claims)")
        try #require(claims.contains(Shortcut("b", modifiers: [.command])), "Cmd-B is not the user's: \(claims)")
        registry.unbind("newWindow")
        registry.bind("newWindow") { actions.runs.append("newWindow") }
        registry.unbind("toggleSidebar")
        registry.bind("toggleSidebar") { actions.runs.append("toggleSidebar") }
        let menu = Self.menuBar(["newWindow", "toggleSidebar"].compactMap { registry.makeMenuItem(for: $0) })
        try Self.withMenu(menu, harness) { () throws in
            let took1 = try Self.press("N", keyCode: 45, shift: true, in: harness)
            #expect(took1)
            let took2 = try Self.press("b", keyCode: 11, in: harness)
            #expect(took2)
        }
        await Self.wait(within: .seconds(5)) { harness.written.contains("c11n") && harness.written.contains("c11b") }
        #expect(actions.count("newWindow") == 0, "New Window took the Cmd-Shift-N the user's Ghostty config binds")
        #expect(actions.count("toggleSidebar") == 0, "Toggle Sidebar took the Cmd-B the user's Ghostty config binds")
        #expect(harness.written.contains("c11n"), "the Ghostty keybind on Cmd-Shift-N never ran (wrote \(harness.written.debugDescription))")
        #expect(harness.written.contains("c11b"), "the Ghostty keybind on Cmd-B never ran (wrote \(harness.written.debugDescription))")
    }

    /// With the default Ghostty config, Edit's Undo, Redo and Select All take Cmd-Z, Cmd-Shift-Z and
    /// Cmd-A from the terminal before Ghostty (its undo, redo and select_all defaults), and Cmd-Q
    /// is Quit.
    @Test func theDefaultConfigKeepsEditAndQuitOnTheirChords() async throws {
        let harness = try Self.harness(userConfig: "")
        defer { harness.close() }
        let registry = harness.services.registry
        let probe = Probe(), actions = Probe()
        registry.unbind("quit")
        registry.bind("quit") { actions.runs.append("quit") }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = probe
            return item
        }
        let menu = Self.menuBar([
            item("Undo", #selector(Probe.undo(_:)), "z", [.command]),
            // Edit's "z" with Shift, as AppKit matches a synthesized Shift-Z (an uppercase equivalent).
            item("Redo", #selector(Probe.redo(_:)), "Z", [.command]),
            item("Select All", #selector(Probe.selectAll(_:)), "a", [.command]),
        ] + [registry.makeMenuItem(for: "quit")].compactMap { $0 })
        try Self.withMenu(menu, harness) { () throws in
            let took3 = try Self.press("z", keyCode: 6, in: harness)
            #expect(took3)
            #expect(probe.runs == ["undo"], "Cmd-Z in a terminal did not run Edit > Undo")
            let took4 = try Self.press("Z", keyCode: 6, shift: true, in: harness)
            #expect(took4)
            #expect(probe.runs == ["undo", "redo"], "Cmd-Shift-Z in a terminal did not run Edit > Redo")
            let took5 = try Self.press("a", keyCode: 0, in: harness)
            #expect(took5)
            #expect(probe.runs == ["undo", "redo", "selectAll"], "Cmd-A in a terminal did not run Edit > Select All")
            let took6 = try Self.press("q", keyCode: 12, in: harness)
            #expect(took6)
            #expect(actions.count("quit") == 1, "Cmd-Q in a terminal did not quit")
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.written.isEmpty, "the terminal got \(harness.written.debugDescription) for a menu chord")
    }

    /// A TUI that reads the mouse (Claude Code fullscreen, OpenCode) gets Cmd-Z, Cmd-Shift-Z and
    /// Cmd-A from the PTY owner (`sendToProgram`), not Edit > Undo, Redo and Select All; Cmd-C
    /// with nothing selected goes the same way. A shell (no mouse reports) keeps the Edit items.
    @Test func aTUIThatReadsTheMouseGetsItsCommandChords() async throws {
        let harness = try Self.harness(userConfig: "")
        defer { harness.close() }
        let probe = Probe()
        var sent: [String] = []
        let previousSend = TerminalKeyEquivalent.sendToProgram
        defer { TerminalKeyEquivalent.sendToProgram = previousSend }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = probe
            return item
        }
        let menu = Self.menuBar([
            item("Undo", #selector(Probe.undo(_:)), "z", [.command]),
            item("Redo", #selector(Probe.redo(_:)), "Z", [.command]),
            item("Select All", #selector(Probe.selectAll(_:)), "a", [.command]),
        ])
        func pressAll() throws {
            try Self.withMenu(menu, harness) { () throws in
                // After `withMenu` installs the app's hooks: record what reaches the PTY owner.
                TerminalKeyEquivalent.sendToProgram = { _, chord, _ in sent.append(chord); return true }
                _ = try Self.press("z", keyCode: 6, in: harness)
                _ = try Self.press("Z", keyCode: 6, shift: true, in: harness)
                _ = try Self.press("a", keyCode: 0, in: harness)
            }
        }

        try pressAll()
        #expect(probe.runs == ["undo", "redo", "selectAll"], "a shell lost Edit > Undo, Redo or Select All")
        #expect(sent.isEmpty, "a shell's Command chords went to the program: \(sent)")

        // SGR mouse reports, as Claude Code's fullscreen mode and OpenCode ask for.
        harness.io.send(.output(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)))
        await Self.wait(within: .seconds(5)) { harness.session.surfaceView.programCapturesMouse }
        try #require(harness.session.surfaceView.programCapturesMouse, "the program never captured the mouse")
        probe.runs = []
        try pressAll()
        #expect(probe.runs.isEmpty, "Edit took a TUI's chord: \(probe.runs)")
        #expect(sent == ["super+z", "super+shift+z", "super+a"], "the program got \(sent)")

        sent = []
        TerminalKeyEquivalent.sendToProgram = { _, chord, _ in sent.append(chord); return true }
        harness.session.surfaceView.copy(nil)
        #expect(sent == ["super+c"], "Cmd-C with nothing selected did not go to the program: \(sent)")
    }

    /// Without a PTY owner (a scripted or local terminal), Cmd-C with nothing selected still
    /// reaches a Kitty-protocol program through Ghostty's `performable:` copy keybind: CSI 99;9u.
    @Test func cmdCWithNothingSelectedReachesAKittyProgramThroughGhostty() async throws {
        let harness = try Self.harness(userConfig: "")
        defer { harness.close() }
        let previousSend = TerminalKeyEquivalent.sendToProgram
        TerminalKeyEquivalent.sendToProgram = nil
        defer { TerminalKeyEquivalent.sendToProgram = previousSend }
        // Claude Code's keyboard setup (Kitty flags 5, modifyOtherKeys 2) in the chunk that turns on
        // mouse reports, so the mode is applied once the surface reads the mouse.
        harness.io.send(.output(Data("\u{1b}[>5u\u{1b}[>4;2m\u{1b}[?1000h".utf8)))
        await Self.wait(within: .seconds(5)) { harness.session.surfaceView.programCapturesMouse }
        try #require(harness.session.surfaceView.programCapturesMouse, "the program never captured the mouse")
        harness.session.surfaceView.copy(nil)
        await Self.wait(within: .seconds(5)) { harness.written.contains("\u{1b}[99;9u") }
        #expect(harness.written.contains("\u{1b}[99;9u"), "the program got \(harness.written.debugDescription)")
    }
}

import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextTestSupport
import Testing

/// Cmd-V in Home's or the Chief's message box pasted into the terminal beside it
/// (https://github.com/manaflow-ai/cmux/issues/52840): the focus model still named the terminal pane
/// while the click had put the keyboard in the box, and the key router ran the terminal's Paste
/// (`terminalPaste`, `requires: terminalFocused`) on that terminal. An editable text input outside
/// the named terminal owns the edit keys: the router takes none of them, so AppKit gives them to it.
@MainActor @Suite(.closesItsWindows, .serialized) struct EditKeysFollowTheClickedInputTests {
    private static var timestamp: TimeInterval = 5_000

    /// A cmux window whose focus model names a terminal pane, and an editable text view of the window
    /// (a message box) that has the keyboard.
    private static func harness() throws -> (AppServices, WindowController, NSWindow, NSTextView) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["paste-52840"]))
        let window = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "paste-52840", panes: [
            .init(id: "terminal-pane", tabs: [.init(id: "terminal-tab", kind: .terminal)], selected: "terminal-tab"),
        ])))
        controller.focus.send(.focusPane("terminal-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "terminal-pane", tab: "terminal-tab"),
                     "the window's focus is \(controller.focus.state.resolved), not its terminal")
        let box = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        box.isEditable = true
        try #require(window.contentView).addSubview(box)
        return (services, controller, window, box)
    }

    private static func command(_ key: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, characters: key,
                                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
    }

    @Test func aMessageBoxWithTheKeyboardKeepsCmdVFromTheNamedTerminal() throws {
        let (services, controller, window, box) = try Self.harness()
        defer { for controller in services.windows.controllers { controller.window?.close() }; AppHarnessWindows.closeThoseThisTestOpened() }
        let router = services.keyRouter

        // The model names the terminal and nothing else has the keyboard: Cmd-V is the terminal's Paste.
        let before = router.keyContext(for: controller.focus.state, facts: router.facts(in: window, controller: controller))
        #expect(before.bits.contains(.terminalFocused))

        // A click put the caret in the message box; the model still names the terminal.
        try #require(window.makeFirstResponder(box), "the message box never took the keyboard")
        try #require(window.firstResponder === box)
        let facts = router.facts(in: window, controller: controller)
        #expect(facts.typingOutsideFocusedTerminal, "the box's keyboard went unseen")
        let context = router.keyContext(for: controller.focus.state, facts: facts)
        #expect(!context.bits.contains(.terminalFocused), "terminal shortcuts still apply while the box has the keyboard")

        for (key, code) in [("v", UInt16(9)), ("c", 8), ("a", 0)] {
            let event = try Self.command(key, keyCode: code, in: window)
            let candidate = router.candidate(for: event, focus: controller.focus.state, facts: facts)
            #expect(candidate.map { !["terminalPaste", "terminalCopy", "terminal.selectAll"].contains($0.id.rawValue) } ?? true,
                    "Cmd-\(key.uppercased()) ran \(candidate?.id.rawValue ?? "-") on the terminal instead of the message box")
        }
        let paste = try Self.command("v", keyCode: 9, in: window)
        let consumed = router.dispatchingSynthetic(paste) { router.interceptKeyDown(paste, in: window) }
        #expect(!consumed, "the router took Cmd-V; AppKit never gave it to the message box")
    }

    /// Diagnostic only (side branch, never merged): what the window, the focus model and the router see around the box's
    /// first-responder change.
    @Test func diagnoseTheMessageBoxFacts() throws {
        let (services, controller, window, box) = try Self.harness()
        defer { for controller in services.windows.controllers { controller.window?.close() }; AppHarnessWindows.closeThoseThisTestOpened() }
        let router = services.keyRouter
        func dump(_ label: String) {
            let s = controller.focus.state
            print("DIAG \(label): resolved=\(s.resolved) pane=\(String(describing: s.pane)) target=\(s.target) overlays=\(s.overlays) panes=\(s.topology.panes.map(\.id)) ws=\(String(describing: s.topology.workspace)) terminal=\(s.context.terminal) windowKey=\(s.windowKey)")
            print("DIAG \(label): recent=\(controller.focus.recent.suffix(10))")
            print("DIAG \(label): firstResponder=\(String(describing: window.firstResponder.map { type(of: $0) })) content=\(controller.content != nil) contentPanes=\(controller.content.map { Array($0.panes.keys) } ?? []) topPage=\(String(describing: controller.shownTopPage)) boxHidden=\(box.isHiddenOrHasHiddenAncestor) boxInWindow=\(box.window === window) shell=\(controller.window === window) isKey=\(window.isKeyWindow) visible=\(window.isVisible)")
            print("DIAG \(label): typingOutside=\(router.typingOutsideFocusedTerminal(window, controller: controller)) currentStateResolved=\(controller.focus.currentState().resolved)")
        }
        dump("before")
        let moved = window.makeFirstResponder(box)
        print("DIAG moved=\(moved) classify=\(FocusResponderClassifier.classify(box, in: controller))")
        dump("after")
    }

    /// The Chief chat as a Chromium page: its page window over the cmux window has the keys while the
    /// model still names the terminal. A key in that window is the page's, never the terminal's.
    @Test func aPageWindowOverTheShellKeepsCmdVFromTheNamedTerminal() throws {
        let (services, controller, window, _) = try Self.harness()
        let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        defer {
            page.close()
            for controller in services.windows.controllers { controller.window?.close() }
            AppHarnessWindows.closeThoseThisTestOpened()
        }
        window.addChildWindow(page, ordered: .above)
        let router = services.keyRouter
        #expect(!router.facts(in: window, controller: controller).typingOutsideFocusedTerminal, "the shell itself lost its terminal's keys")
        let facts = router.facts(in: page, controller: controller)
        #expect(facts.typingOutsideFocusedTerminal, "the page window's keys were taken for the terminal")
        #expect(!router.keyContext(for: controller.focus.state, facts: facts).bits.contains(.terminalFocused))
        let event = try Self.command("v", keyCode: 9, in: page)
        let candidate = router.candidate(for: event, focus: controller.focus.state, facts: facts)
        #expect(candidate?.id.rawValue != "terminalPaste", "Cmd-V in the page ran the terminal's Paste")
    }

    /// The pure rule: the fact clears only the terminal bit.
    @Test func theFactClearsOnlyTheTerminalBit() {
        var focus = FocusState()
        focus.resolved = .terminal(pane: "p", tab: "t")
        focus.context.terminal = true
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts()).bits.contains(.terminalFocused))
        let typing = KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts(typingOutsideFocusedTerminal: true))
        #expect(!typing.bits.contains(.terminalFocused))
    }
}

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

    /// The window reports a first responder change to the focus model (`ShellWindow.reportResponder`), so a message box
    /// that takes the keyboard moves the model to a text field, and terminal shortcuts stop applying. While the report
    /// is held (an edit's teardown, `endEditing(for:)`), the model still names the terminal: then the box's keyboard
    /// alone (`typingOutsideFocusedTerminal`) keeps the edit keys from the terminal. Both must leave Cmd-V, Cmd-C and
    /// Cmd-A to the box.
    @Test func aMessageBoxWithTheKeyboardKeepsCmdVFromTheNamedTerminal() throws {
        let (services, controller, window, box) = try Self.harness()
        defer { for controller in services.windows.controllers { controller.window?.close() }; AppHarnessWindows.closeThoseThisTestOpened() }
        let router = services.keyRouter
        let shell = try #require(window as? ShellWindow)
        let control = try Self.editKeys(in: window), held = try Self.editKeys(in: window), settled = try Self.editKeys(in: window)

        // The model names the terminal and nothing else has the keyboard: Cmd-V is the terminal's Paste and Cmd-C its
        // Copy (the control: the checks below see a key bound for the terminal).
        let beforeFacts = router.facts(in: window, controller: controller)
        #expect(router.keyContext(for: controller.focus.state, facts: beforeFacts).bits.contains(.terminalFocused))
        #expect(router.candidate(for: control[0].event, focus: controller.focus.state, facts: beforeFacts)?.id.rawValue == "terminalPaste")
        #expect(router.candidate(for: control[1].event, focus: controller.focus.state, facts: beforeFacts)?.id.rawValue == "terminalCopy")

        // A click put the caret in the message box while the window held its responder report: the model still
        // names the terminal.
        shell.holdingResponderReports {
            #expect(window.makeFirstResponder(box), "the message box never took the keyboard")
            #expect(window.firstResponder === box)
            #expect(controller.focus.state.resolved == .terminal(pane: "terminal-pane", tab: "terminal-tab"),
                    "the model left the terminal before the window reported the box (\(controller.focus.state.resolved))")
            #expect(router.facts(in: window, controller: controller).typingOutsideFocusedTerminal, "the box's keyboard went unseen")
            Self.expectEditKeysReachTheBox(held, router: router, controller: controller, window: window, box: box, while: "the report is held")
        }

        // The hold ended: the window reported the box, and the model names a text field.
        #expect(controller.focus.state.resolved == .textField, "the model never followed the box (\(controller.focus.state.resolved))")
        Self.expectEditKeysReachTheBox(settled, router: router, controller: controller, window: window, box: box, while: "the model names the box")
    }

    /// Cmd-V, Cmd-C and Cmd-A key-downs in `window`, Cmd-V first.
    private static func editKeys(in window: NSWindow) throws -> [(key: String, event: NSEvent)] {
        try [("v", UInt16(9)), ("c", 8), ("a", 0)].map { ($0.0, try command($0.0, keyCode: $0.1, in: window)) }
    }

    /// Where each of `keys` lands: the router decides none of the terminal's Paste, Copy or Select All, dispatches it
    /// without running any action, and hands it on to AppKit, whose key goes to the window's first responder, the box.
    private static func expectEditKeysReachTheBox(_ keys: [(key: String, event: NSEvent)], router: KeyRouter, controller: WindowController,
                                                  window: NSWindow, box: NSTextView, while when: String) {
        let facts = router.facts(in: window, controller: controller)
        #expect(!router.keyContext(for: controller.focus.state, facts: facts).bits.contains(.terminalFocused),
                "terminal shortcuts still apply while the box has the keyboard (\(when))")
        for (key, event) in keys {
            let name = "Cmd-\(key.uppercased())"
            let candidate = router.candidate(for: event, focus: controller.focus.state, facts: facts)
            #expect(candidate.map { !["terminalPaste", "terminalCopy", "terminal.selectAll"].contains($0.id.rawValue) } ?? true,
                    "\(name) ran \(candidate?.id.rawValue ?? "-") on the terminal instead of the message box (\(when))")
            let consumed = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
            #expect(!consumed, "the router took \(name); AppKit never gave it to the message box (\(when))")
            let ran = router.lastInterception?.action.rawValue
            #expect(ran == nil, "\(name) ran \(ran ?? "-") (\(when))")
            #expect(window.firstResponder === box, "\(name) moved the keyboard off the message box (\(when))")
        }
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

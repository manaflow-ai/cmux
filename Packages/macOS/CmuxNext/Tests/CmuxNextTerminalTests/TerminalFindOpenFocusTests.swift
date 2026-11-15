import AppKit
@testable import CmuxNextTerminal
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Cmd-F in a terminal: the find field has the keyboard as soon as `open()` returns, so the key
/// typed right after Cmd-F lands in the query and not in the shell. The first Cmd-F used to build
/// the bar a main-actor hop later and asked for focus before the bar was in the window, so that
/// first press left the keyboard on the terminal.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TerminalFindOpenFocusTests {
    struct Terminal {
        let session: TerminalSession
        let io: ScriptedTerminalIO
    }

    /// Live terminals side by side in one borderless window.
    struct Harness {
        let terminals: [Terminal]
        let window: NSWindow

        func close() {
            for terminal in terminals { terminal.io.finish() }
            window.contentView = nil
            window.close()
        }
    }

    static func harness(terminals count: Int = 1) throws -> Harness {
        _ = NSApplication.shared
        let width: CGFloat = 480
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width * CGFloat(count), height: 240))
        var terminals: [Terminal] = []
        for index in 0..<count {
            let io = ScriptedTerminalIO()
            let session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            session.view.frame = NSRect(x: width * CGFloat(index), y: 0, width: width, height: 240)
            container.addSubview(session.view)
            terminals.append(Terminal(session: session, io: io))
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return Harness(terminals: terminals, window: window)
    }

    /// Types `characters` the way AppKit delivers a key-down: to whatever has the keyboard now.
    static func type(_ characters: String, in window: NSWindow) throws {
        for character in characters {
            let text = String(character)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 14))
            let responder = try #require(window.firstResponder, "nothing has the keyboard")
            responder.keyDown(with: event)
        }
    }

    static func bar(of session: TerminalSession) -> TerminalFindBarView? {
        session.view.subviews.lazy.compactMap { $0 as? TerminalFindBarView }.first
    }

    /// Opens find the way Cmd-F does, with the terminal holding the keyboard, then types at once:
    /// no run-loop turn between the shortcut and the next key.
    static func cmdFThenType(_ text: String, in session: TerminalSession, window: NSWindow) throws {
        try #require(window.makeFirstResponder(session.surfaceView), "the terminal did not take the keyboard")
        session.find.open()
        let bar = try #require(Self.bar(of: session), "Cmd-F did not build the find bar before returning")
        #expect(bar.pill.isPresented, "Cmd-F did not show the find bar")
        #expect(FindPillView.ownsFieldEditor(window.firstResponder),
                "Cmd-F left the keyboard on \(String(describing: window.firstResponder)), not the find field")
        try Self.type(text, in: window)
        #expect(session.find.query == text, "the keys typed right after Cmd-F did not reach the find field")
    }

    @Test func theFirstCmdFFocusesTheFieldBeforeTheNextKey() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let session = harness.terminals[0].session
        #expect(Self.bar(of: session) == nil, "the bar is built on first use, not with the terminal")
        try Self.cmdFThenType("err", in: session, window: harness.window)
    }

    @Test func cmdFAfterClosingFocusesTheFieldWithTheQuerySelected() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let session = harness.terminals[0].session
        try Self.cmdFThenType("err", in: session, window: harness.window)
        session.find.close()
        #expect(harness.window.firstResponder === session.surfaceView, "closing did not give the keyboard back")
        // The last query comes back selected, so typing replaces it.
        try Self.cmdFThenType("warn", in: session, window: harness.window)
    }

    @Test func eachTerminalsFirstCmdFFocusesItsOwnField() throws {
        let harness = try Self.harness(terminals: 2)
        defer { harness.close() }
        let first = harness.terminals[0].session, second = harness.terminals[1].session
        try Self.cmdFThenType("one", in: first, window: harness.window)
        try Self.cmdFThenType("two", in: second, window: harness.window)
        #expect(first.find.query == "one", "typing in the second terminal's field changed the first's query")
    }

    @Test func ghosttysOwnSearchKeybindFocusesTheFieldOnItsFirstUse() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let session = harness.terminals[0].session
        try #require(harness.window.makeFirstResponder(session.surfaceView))
        session.find.searchStarted(needle: "")
        #expect(FindPillView.ownsFieldEditor(harness.window.firstResponder),
                "Ghostty's start_search left the keyboard on the terminal")
        try Self.type("x", in: harness.window)
        #expect(session.find.query == "x")
    }

    @Test func aSocketOpenShowsTheBarAndLeavesTheKeyboardOnTheTerminal() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let session = harness.terminals[0].session
        try #require(harness.window.makeFirstResponder(session.surfaceView))
        session.find.open(seed: "err", takeFocus: false)
        let bar = try #require(Self.bar(of: session), "a socket open did not build the find bar")
        #expect(bar.pill.isPresented)
        #expect(harness.window.firstResponder === session.surfaceView, "a socket open took the keyboard")
    }
}

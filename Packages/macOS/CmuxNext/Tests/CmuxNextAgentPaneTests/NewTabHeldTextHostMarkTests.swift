import AppKit
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// The text of a held key that a New Tab page's view takes while cmux is not the active app marks that view
/// (`AgentPaneHostTouch`).
///
/// `AgentPaneView.typeHeldText(of:appIsActive:)` gives the text to a task of the view, and the page gets it later.
/// Such a key does not go through `AgentPaneView.judge(_:eventWindow:)`, which sets the host's mark for a key
/// event. With no mark the view is an untouched New Tab view until its page reports the input
/// (`AgentPaneView.isUntouchedNewTab`), and an untouched New Tab view can go to the next New Tab tab: the text then
/// lands in the wrong tab. So the view sets the mark itself, at the call, before its page gets the text.
///
/// - A key whose text the view takes sets the mark, and the mark is there when the call returns.
/// - After that the view is no untouched New Tab view.
/// - A key whose text the view does not take (the app is active, a key with Command, Return) sets no mark here, and
///   the view stays an untouched New Tab view. Such a key goes on as a key event, whose own path sets the mark.
///
/// The scene is that of `HeldKeyWhileAppInactiveTests`, with a New Tab page in the model. The page is a fake
/// Chromium page: no engine runs, and no page reports an input. Limits: the rows do not prove which view the app
/// gives to the next tab; `NewTabHostMarkTests` has that for a mark.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct NewTabHeldTextHostMarkTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A view with a New Tab page on a fake Chromium page, in a window. Nothing went to the page.
    private func pane() async throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        let view = try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        chromium.answer = { method, _ in method == "Runtime.evaluate" ? #"{"result":{"type":"boolean","value":true}}"# : nil }
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        try #require(!view.model.hostTouch.marked, "setup: the view has the host's mark before the row's key, by \(view.model.hostTouch.by ?? "?")")
        try #require(view.isUntouchedNewTab, "setup: the view is no untouched New Tab view before the row's key: the row then proves nothing")
        return (view, window)
    }

    private static func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: 0))
    }

    /// What the mark of `view` says, for a row's print.
    private static func state(_ view: AgentPaneView) -> String {
        "the host's mark = \(view.model.hostTouch.marked), by \(view.model.hostTouch.by ?? "none"); an untouched New Tab view = \(view.isUntouchedNewTab)"
    }

    /// The mark is read directly after the call: that is before the view's task gives the text to the page.
    @Test func theTextOfAHeldKeyMarksTheViewBeforeThePageGetsIt() async throws {
        let (view, window) = try await pane()
        defer { view.page?.close(); window.close() }
        let took = view.typeHeldText(of: try Self.key("m"), appIsActive: false)
        let marked = view.model.hostTouch.marked, by = view.model.hostTouch.by
        await view.heldKeyTyping?.value
        print("NewTabHeldTextHostMarkTests: a held letter while the app is not active: the view took its text = \(took); directly after the call the mark = \(marked), by \(by ?? "none")")
        try #require(took, "setup: the view did not take the held key's text")
        #expect(marked && by == "held-key", "the view took a held key's text and set no mark of it: the mark = \(marked), by \(by ?? "none")")
    }

    /// What a person gets from the mark: the view with the text cannot go to the next New Tab tab.
    @Test func aViewThatTookTheTextOfAHeldKeyIsNoUntouchedNewTabView() async throws {
        let (view, window) = try await pane()
        defer { view.page?.close(); window.close() }
        let took = view.typeHeldText(of: try Self.key("m"), appIsActive: false)
        let untouched = view.isUntouchedNewTab
        await view.heldKeyTyping?.value
        print("NewTabHeldTextHostMarkTests: directly after the view took a held letter's text: an untouched New Tab view = \(untouched); after the page got the text: \(Self.state(view))")
        try #require(took, "setup: the view did not take the held key's text")
        #expect(!untouched, "a view that took a held key's text is an untouched New Tab view: the next New Tab tab can take it, with the text")
        #expect(view.model.userTouched && !view.isUntouchedNewTab, "after the page got the text: \(Self.state(view))")
    }

    @Test func aKeyThatTheViewDoesNotTakeSetsNoMark() async throws {
        let (view, window) = try await pane()
        defer { view.page?.close(); window.close() }
        let active = view.typeHeldText(of: try Self.key("m"), appIsActive: true)
        let command = view.typeHeldText(of: try Self.key("t", modifiers: .command), appIsActive: false)
        let enter = view.typeHeldText(of: try Self.key("\r"), appIsActive: false)
        await view.heldKeyTyping?.value
        print("NewTabHeldTextHostMarkTests: the view took a letter while the app is active = \(active), a key with Command = \(command), Return = \(enter); then: \(Self.state(view))")
        try #require(!active && !command && !enter, "setup: the view took the text of a key that must stay a key event")
        #expect(!view.model.hostTouch.marked, "a key that the view did not take set the host's mark: \(Self.state(view))")
        #expect(view.isUntouchedNewTab, "a key that the view did not take made the view a touched one: \(Self.state(view))")
    }
}

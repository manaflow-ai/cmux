import AppKit
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-ocdz at the pane's gesture monitor: a click that another process posts (CGEventPost: a
/// computer-use agent, a script) on the permission card reaches the page, but it is not the
/// person's gesture, so the Allow it sends grants nothing and the prompt stays pending (cx-1l61).
/// A click from the HID system (source pid 0) is the person's.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPanePostedClickTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A left click at the middle of `window`'s content, as if posted by process `source`.
    static func click(in window: NSWindow, source: Int64) throws -> NSEvent {
        let frame = window.frame
        // CGEvent locations are top-left based; NSEvent flips them with the main display's height.
        let point = CGPoint(x: frame.midX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.midY)
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
                                           mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: source)
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test func aClickPostedByAnotherProcessGrantsNothingAndThePersonsDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "posted-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body><button>Allow</button></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let gestures = view.model.transport.gestures

        // Another process (not this one, not the HID system) posted the click on Allow.
        let foreign = Int64(getpid()) + 1
        let posted = try Self.click(in: window, source: foreign)
        try #require(view.webView.bounds.contains(view.webView.convert(posted.locationInWindow, from: nil)),
                     "the test click misses the page (\(posted.locationInWindow)); the check below would prove nothing")
        view.judge(posted, eventWindow: window)
        #expect(!gestures.isAvailable, "a click another process posted counted as the person's gesture")
        #expect(!gestures.consume(), "a posted click left a grant the page's Allow would use")

        // The person's own click (the HID system's events carry source pid 0).
        view.judge(try Self.click(in: window, source: 0), eventWindow: window)
        #expect(gestures.consume(), "the person's click did not count as a gesture")
    }

    /// A tab the pane stopped showing stays in it, pane-sized (PaneContentView+Parking): hidden, or under
    /// the tab shown. A click in the shown tab is its gesture only: the parked view records none, so a
    /// delayed request from its page (Set Up Computer Use's `action.run`) cannot spend that click.
    @Test func aClickInTheShownTabGrantsNoGestureToAParkedViewInThePane() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "parked-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body><button>Ask</button></body></html>".utf8).write(to: file)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let shown = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let parked = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { shown.close(); parked.close(); window.close() }
        let pane = NSView(frame: frame)
        window.contentView = pane
        for view in [shown, parked] {
            view.frame = frame
            pane.addSubview(view)
            view.layoutSubtreeIfNeeded()
        }
        let click = { try Self.click(in: window, source: 0) }
        try #require(parked.webView.bounds.contains(parked.webView.convert(try click().locationInWindow, from: nil)),
                     "setup: the click misses the parked page; the checks below would prove nothing")

        // Hidden, and above the shown tab in the pane's subviews (a switch moves no view).
        parked.isHidden = true
        parked.judge(try click(), eventWindow: window)
        #expect(!parked.model.transport.gestures.isAvailable, "a hidden parked view recorded the shown tab's click")
        shown.judge(try click(), eventWindow: window)
        #expect(shown.model.transport.gestures.consume(), "the shown tab's own click did not count")

        // Not hidden but under the tab shown: the click lands in the shown tab, not in it.
        parked.isHidden = false
        pane.addSubview(shown, positioned: .above, relativeTo: parked)
        parked.judge(try click(), eventWindow: window)
        #expect(!parked.model.transport.gestures.isAvailable, "a covered view recorded the click on the view over it")
        shown.judge(try click(), eventWindow: window)
        #expect(shown.model.transport.gestures.consume(), "the shown tab's own click did not count")
    }

    /// A screenshot/file interaction can leave Chromium's child window temporarily not key while
    /// the pane still receives the person's Return. The send must keep its person proof in that
    /// transition; otherwise an attached prompt is refused as “Not sent”.
    @Test func aReturnFromChromiumStillCountsWhileHeldOrItsChildWindowIsNotKey() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: hosting))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let paneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        paneWindow.isReleasedWhenClosed = false
        paneWindow.contentView = view
        defer { view.close(); paneWindow.close() }
        view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsChromium, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.debugShowsChromium)
        let chromiumView = try #require(view.chromiumPage?.contentView)
        let childWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        childWindow.isReleasedWhenClosed = false
        paneWindow.addChildWindow(childWindow, ordered: .above)
        defer { childWindow.close() }
        chromiumView.removeFromSuperview()
        childWindow.contentView = chromiumView
        chromiumView.frame = childWindow.contentView?.bounds ?? .zero

        #expect(!childWindow.isKeyWindow)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let keyDown = try #require(NSEvent(cgEvent: event))
        let gestures = view.model.transport.gestures
        view.judge(keyDown, eventWindow: childWindow)
        #expect(gestures.consume(), "the person's Return after an attachment was rejected while Chromium was not key")
        // Consuming the ordinary grant is a separate use of this physical key. It revokes the
        // question proof, so the same event cannot authorize both paths.
        #expect(gestures.questionReturnWitness == nil)

        // A second physical Return exercises the isolated question proof independently.
        let questionEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        questionEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let questionKeyDown = try #require(NSEvent(cgEvent: questionEvent))
        view.judge(questionKeyDown, eventWindow: childWindow)
        let witness = try #require(gestures.questionReturnWitness)
        #expect(gestures.isAvailable, "the question Return also has its ordinary grant credit")
        // A held Return can repeat while the isolated DOM proof is still crossing the bridge.
        // It must neither revoke that original witness nor mint another one.
        questionEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let repeated = try #require(NSEvent(cgEvent: questionEvent))
        try #require(repeated.isARepeat)
        view.judge(repeated, eventWindow: childWindow)
        #expect(gestures.questionReturnWitness == witness)
        #expect(gestures.isAvailable, "a held Return repeat neither mints nor consumes generic credit")
        #expect(gestures.consumeQuestionReturn(witness))
        #expect(!gestures.consume(), "consuming the question proof must revoke its generic grant")
        #expect(!gestures.consumeQuestionReturn(witness))

        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        view.judge(try #require(NSEvent(cgEvent: event)), eventWindow: childWindow)
        let next = try #require(gestures.questionReturnWitness)
        // The numeric keypad's Enter is a distinct native key (76), but it is still Return
        // for the isolated question-key listener.
        event.setIntegerValueField(.keyboardEventKeycode, value: 76)
        view.judge(try #require(NSEvent(cgEvent: event)), eventWindow: childWindow)
        let keypad = try #require(gestures.questionReturnWitness)
        #expect(!gestures.consumeQuestionReturn(next), "keypad Enter revived the previous Return proof")
        #expect(gestures.consumeQuestionReturn(keypad), "keypad Enter did not mint a Return proof")
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()) + 1)
        view.judge(try #require(NSEvent(cgEvent: event)), eventWindow: childWindow)
        #expect(!gestures.consumeQuestionReturn(keypad), "new posted page input left the keypad proof usable")
    }

    /// Review round 2 of #48024: in a paint hold a new view lies at alpha 0 over the view that still shows, and both
    /// Chromium pages sit at the same rect. A click or key in the shown page's window is that pane's gesture only: the
    /// new view records none, so a deferred request from its page cannot spend the outgoing page's input.
    @Test func overlappingChromiumPagesCreditOnlyThePaneWhosePageShows() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let paneWindow = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        paneWindow.isReleasedWhenClosed = false
        let root = NSView(frame: frame)
        paneWindow.contentView = root
        let make = { try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true, testRoot: true,
                                                chromium: FakeChromiumHosting())) }
        let outgoing = try make(), incoming = try make()
        let hold = NSView(frame: frame)
        hold.alphaValue = 0
        outgoing.frame = frame
        incoming.frame = hold.bounds
        root.addSubview(outgoing)
        root.addSubview(hold, positioned: .above, relativeTo: outgoing)
        hold.addSubview(incoming)
        var pageWindows: [NSWindow] = []
        defer {
            outgoing.close(); incoming.close()
            for window in pageWindows { window.close() }
            paneWindow.close()
        }
        root.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while !(outgoing.debugShowsChromium && incoming.debugShowsChromium), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(outgoing.debugShowsChromium && incoming.debugShowsChromium, "setup: a page never showed in Chromium")
        // Each Chromium page draws in its own child window of the pane's window, both at the same rect.
        for view in [outgoing, incoming] {
            let content = try #require(view.chromiumPage?.contentView)
            let page = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            paneWindow.addChildWindow(page, ordered: .above)
            content.removeFromSuperview()
            page.contentView = content
            pageWindows.append(page)
        }
        PageWebView.syncChromiumVisibility(in: root)
        try #require(outgoing.page?.chromiumShows == true, "setup: the outgoing page does not show")
        try #require(incoming.page?.chromiumShows != true, "setup: the held page shows")
        let shown = pageWindows[0]

        incoming.judge(try Self.click(in: shown, source: 0), eventWindow: shown)
        #expect(!incoming.model.transport.gestures.isAvailable, "the held view recorded the shown page's click")
        outgoing.judge(try Self.click(in: shown, source: 0), eventWindow: shown)
        #expect(outgoing.model.transport.gestures.consume(), "the shown page's own click did not count")

        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        key.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let returnKey = try #require(NSEvent(cgEvent: key))
        incoming.judge(returnKey, eventWindow: shown)
        #expect(!incoming.model.transport.gestures.isAvailable, "the held view recorded the shown page's Return")
        outgoing.judge(returnKey, eventWindow: shown)
        #expect(outgoing.model.transport.gestures.consume(), "the shown page's own Return did not count")
    }

    /// While the person types, a click another process posts on Allow must not spend the typing's
    /// gesture: an allow needs the person's own click (or permission shortcut) from just now.
    @Test func aTypingGestureNeverAnswersAPermissionAndAnOldClickExpires() {
        final class Clock { var now: TimeInterval = 100 }
        let clock = Clock()
        let gestures = AgentPaneUserGestures(now: { clock.now })
        gestures.record(click: false)
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/permission_respond", gestures),
                "a keystroke's gesture answered a permission prompt")
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/permission_group_respond", gestures))
        #expect(AcpmuxPaneMethods.answerAllowed("session/prompt", gestures), "a send still uses the typing gesture")
        gestures.record(click: true)
        #expect(AcpmuxPaneMethods.answerAllowed("_acpmux/permission_respond", gestures), "the person's click did not answer")
        clock.now += AgentPaneUserGestures.answerWindow + 0.5
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/permission_respond", gestures), "an old click still answered")
    }
}

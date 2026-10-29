import AppKit
import CmuxNextPagesTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-ocdz at the pane's gesture monitor: a click that another process posts (CGEventPost: a
/// computer-use agent, a script) on the permission card reaches the page, but it is not the
/// person's gesture, so the Allow it sends grants nothing and the prompt stays pending (cx-1l61).
/// A click from the HID system (source pid 0) is the person's.
@Suite(.serialized)
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

    /// A screenshot/file interaction can leave Chromium's child window temporarily not key while
    /// the pane still receives the person's Return. The send must keep its person proof in that
    /// transition; otherwise an attached prompt is refused as “Not sent”.
    @Test func aReturnFromChromiumStillCountsWhenItsChildWindowIsNotKey() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
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

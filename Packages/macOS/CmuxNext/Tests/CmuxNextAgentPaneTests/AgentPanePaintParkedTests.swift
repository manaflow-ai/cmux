import AppKit
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-11-17, on a Cloud chat's start: "when the machine gets created, this whole chat thread
/// blinks and loads again and then starts the response". The machine's chat page now draws out of
/// sight in the window first (``AgentPaneView/paintParked(in:size:within:)``) and shows once painted.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPanePaintParkedTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func page() throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.orderFrontRegardless()
        return (view, window)
    }

    @Test func aChatPageDrawsOutOfSightAndReturnsOnceItPainted() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        let waiting = Task { await view.paintParked(in: window, size: CGSize(width: 320, height: 240), within: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        let parking = try #require(view.superview as? PageOffscreenParking, "the page was not laid out in the window before it showed")
        #expect(parking.superview === window.contentView)
        #expect(!parking.frame.intersects(window.contentView?.bounds ?? .zero), "the parked page lay in sight")
        #expect(view.frame.size == CGSize(width: 320, height: 240), "the page drew at another size than the pane it shows in")
        view.model.markPainted()
        #expect(await waiting.value, "the wait did not end with the page's first paint")
    }

    /// cmux#55519: while it waits to paint, the parked page is held drawing (``AgentPaneView/holdsPageAway``), so its engine
    /// never reports it hidden and throttles it; the hold ends with the wait. RED before: nothing held it, and a Cloud start's
    /// chat page reported hidden once its document drew, then painted only when the 20 s bound gave up.
    @Test func aParkedPageIsHeldDrawingUntilItPaintsThenLetGo() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        #expect(!view.holdsPageAway)
        let waiting = Task { await view.paintParked(in: window, size: CGSize(width: 320, height: 240), within: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.holdsPageAway, "the parked page was not held drawing while it waited")
        view.model.markPainted()
        #expect(await waiting.value)
        #expect(!view.holdsPageAway, "the hold outlived the wait")
        #expect(await view.paintParked(in: window, size: CGSize(width: 320, height: 240), within: .milliseconds(50)) || !view.holdsPageAway)
    }

    @Test func aPageThatNeverPaintsShowsAfterTheBound() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        #expect(await view.paintParked(in: window, size: CGSize(width: 320, height: 240), within: .milliseconds(50)) == false)
    }

    @Test func aPageAlreadyInAPaneStaysThere() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(await view.paintParked(in: window, size: CGSize(width: 320, height: 240), within: .milliseconds(50)) == false)
        #expect(view.superview === window.contentView)
    }
}

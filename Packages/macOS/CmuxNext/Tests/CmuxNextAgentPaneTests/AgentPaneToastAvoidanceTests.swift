import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A toast host that counts the times the window's avoidance link moves its toasts (the native
/// toast host slides its toasts above the new floor there).
@MainActor
private final class ReanchorSpy: CmuxToastReanchoring {
    var reanchors = 0
    func reanchor(in window: NSWindow) { reanchors += 1 }
}

private actor NoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

/// A toast never covers the composer, and the composer never moves for a toast (Leo, 2026-11-07:
/// "The composer should never ever rise up because there's some sort of ... tooltip type thing").
/// The page reports its bottom stack; the toast host lifts the toasts above it (the floor of
/// `CmuxToastAvoidance.floor`, where `CmuxToastOverlayHost` rests them), and the pane tells the page nothing about toasts.
@MainActor @Suite(.closesItsWindows)
struct AgentPaneToastAvoidanceTests {
    /// The page's report decodes to one box or none; more than one, or a bad one, is refused.
    @Test func reportsDecodeAndBadOnesAreRefused() {
        let one = AgentPaneRequest(body: ["id": "t", "method": "pane.toastAvoidance", "params": [
            "rects": [["left": 20, "top": 600, "right": 880, "bottom": 690]],
        ]])
        #expect(one == .toastAvoidance(CGRect(x: 20, y: 600, width: 860, height: 90)))
        #expect(String(describing: one) == "toastAvoidance")
        #expect(AgentPaneRequest(body: ["id": "t", "method": "pane.toastAvoidance", "params": ["rects": []]]) == .toastAvoidance(nil))
        let two = AgentPaneRequest(body: ["id": "t", "method": "pane.toastAvoidance", "params": [
            "rects": [["left": 0, "top": 0, "right": 1, "bottom": 1], ["left": 0, "top": 0, "right": 1, "bottom": 1]],
        ]])
        #expect(two == .unsupported("pane.toastAvoidance"))
        let inverted = AgentPaneRequest(body: ["id": "t", "method": "pane.toastAvoidance", "params": [
            "rects": [["left": 880, "top": 600, "right": 20, "bottom": 690]],
        ]])
        #expect(inverted == .unsupported("pane.toastAvoidance"))
    }

    /// A toast over an agent pane rests above its reported composer: the stack's floor is over it.
    /// The pane neither reserves room for toasts nor changes what it avoids while a toast shows.
    @Test func aToastRestsAboveTheComposerAndTheComposerStays() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.isReleasedWhenClosed = false
            window.close()
            panel?.close()
        }
        view.frame = try #require(window.contentView).bounds
        try #require(window.contentView).addSubview(view)
        view.layoutSubtreeIfNeeded()
        #expect((view as NSView) as? any CmuxToastReserving == nil, "the pane must not make room for toasts")

        // The composer card 90 px tall, its bottom 10 px over the page's foot.
        let pageHeight = (view.page?.frame ?? view.webView.frame).height
        _ = await view.model.respond(to: .toastAvoidance(CGRect(x: 20, y: pageHeight - 100, width: 860, height: 90)))
        let composer = view.convert(view.toastAvoidanceRect, to: nil)
        #expect(composer.height > 89 && composer.height < 91)
        #expect(composer.minX > 19 && composer.minX < 21)

        let bounds = try #require(window.contentView).bounds
        let floor = CmuxToastAvoidance.floor(width: 400, in: bounds, window: window)
        #expect(floor >= composer.maxY + CmuxToastAvoidance.avoidanceGap - 0.5, "the toast covers the composer")
        #expect(view.convert(view.toastAvoidanceRect, to: nil) == composer, "the composer moved for a toast")

        // The page reports no stack: the toast rests at the window's foot.
        _ = await view.model.respond(to: .toastAvoidance(nil))
        #expect(view.toastAvoidanceRect.isEmpty)
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) == bounds.minY)
    }

    /// A workspace switch hides an ancestor and changes no frame. A toast shown while the chat was
    /// away rests at the window's foot; when the chat shows again, the toast host is told to move it
    /// above the composer (review of #37545: it stayed over the composer until another geometry change).
    @Test func aToastShownWhileThePaneWasHiddenMovesAboveTheComposerWhenItShows() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.isReleasedWhenClosed = false
            window.close()
            panel?.close()
        }
        let content = try #require(window.contentView)
        // The workspace's container, which a switch hides.
        let workspace = NSView(frame: content.bounds)
        content.addSubview(workspace)
        view.frame = workspace.bounds
        workspace.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let pageHeight = (view.page?.frame ?? view.webView.frame).height
        _ = await view.model.respond(to: .toastAvoidance(CGRect(x: 20, y: pageHeight - 100, width: 860, height: 90)))
        let composer = view.convert(view.toastAvoidanceRect, to: nil)

        workspace.isHidden = true
        let bounds = content.bounds
        let spy = ReanchorSpy()
        CmuxToastAvoidance.register(spy, in: window)
        defer { CmuxToastAvoidance.unregister(spy, from: window) }
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) < composer.maxY, "a hidden chat still held the toast up")

        let before = spy.reanchors
        workspace.isHidden = false
        // The move runs one main-actor turn after the change (`CmuxToastAvoidance.avoidanceChanged`).
        for _ in 0..<20 where spy.reanchors == before { await Task.yield() }
        #expect(spy.reanchors > before, "the toast host was not told the chat showed again")
        #expect(CmuxToastAvoidance.floor(width: 400, in: bounds, window: window) >= composer.maxY + CmuxToastAvoidance.avoidanceGap - 0.5,
                "the toast stayed over the composer after the chat showed again")
    }

    /// A chat moved straight to another window at the same window-relative frame: the toast host
    /// there is told to move its toasts, which now rest above the composer, and the window it left
    /// stops avoiding it.
    @Test func aToastInTheWindowAChatMovesToMovesAboveItsComposer() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        }
        defer {
            for window in windows {
                let panel = WindowOverlayHost.existingHost(for: window)?.panel
                window.isReleasedWhenClosed = false
                window.close()
                panel?.close()
            }
        }
        let source = try #require(windows[0].contentView), destination = try #require(windows[1].contentView)
        view.frame = source.bounds
        source.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let pageHeight = (view.page?.frame ?? view.webView.frame).height
        _ = await view.model.respond(to: .toastAvoidance(CGRect(x: 20, y: pageHeight - 100, width: 860, height: 90)))
        let composer = view.convert(view.toastAvoidanceRect, to: nil)

        // The destination window shows a toast and has no chat yet: its stack rests at the window's foot.
        let spy = ReanchorSpy()
        CmuxToastAvoidance.register(spy, in: windows[1])
        defer { CmuxToastAvoidance.unregister(spy, from: windows[1]) }
        #expect(CmuxToastAvoidance.floor(width: 400, in: destination.bounds, window: windows[1]) < composer.maxY)

        let before = spy.reanchors
        destination.addSubview(view) // the same frame in the new window
        view.layoutSubtreeIfNeeded()
        #expect(view.convert(view.toastAvoidanceRect, to: nil) == composer)
        for _ in 0..<20 where spy.reanchors == before { await Task.yield() }
        #expect(spy.reanchors > before, "the toast host in the chat's new window was not told")
        #expect(CmuxToastAvoidance.floor(width: 400, in: destination.bounds, window: windows[1])
                    >= composer.maxY + CmuxToastAvoidance.avoidanceGap - 0.5,
                "the toast in the chat's new window stayed over its composer")
        #expect(CmuxToastAvoidance.floor(width: 400, in: source.bounds, window: windows[0]) == source.bounds.minY,
                "the window the chat left still avoids it")
    }
}

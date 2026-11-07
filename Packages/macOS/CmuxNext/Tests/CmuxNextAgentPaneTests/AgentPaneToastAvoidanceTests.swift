import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
import Testing

private actor NoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

/// A toast never covers the composer, and the composer never moves for a toast (Leo, 2026-11-07:
/// "The composer should never ever rise up because there's some sort of ... tooltip type thing").
/// The page reports its bottom stack; the toast host lifts the toasts above it, and the pane tells
/// the page nothing about toasts.
@MainActor
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

    /// A toast shown over an agent pane rests above its reported composer, and the pane neither
    /// reserves room for toasts nor changes what it avoids while the toast shows.
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

        let host = CmuxToastOverlayHost()
        let handle = CmuxToastCenter(host: host).show(CmuxToast(id: "layout.resizeMode", message: "Snap"), in: window)
        let toast = try #require(Self.toastViews(in: window).first)
        let shown = toast.convert(toast.bounds, to: nil)
        #expect(shown.minY >= composer.maxY + CmuxToastOverlayHost.avoidanceGap - 0.5, "the toast covers the composer")
        #expect(view.convert(view.toastAvoidanceRect, to: nil) == composer, "the composer moved for a toast")
        handle.dismiss()

        // The page reports no stack: the toast rests at the window's foot.
        _ = await view.model.respond(to: .toastAvoidance(nil))
        #expect(view.toastAvoidanceRect.isEmpty)
        let bounds = try #require(window.contentView).bounds
        #expect(CmuxToastOverlayHost.floor(width: 400, in: bounds, window: window) == bounds.minY)
    }

    /// A workspace switch hides an ancestor and changes no frame. A toast shown while the chat was
    /// away rests at the window's foot; when the chat shows again, the toast moves above its composer
    /// (review of #37545: it stayed over the composer until another geometry change).
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
        let host = CmuxToastOverlayHost()
        let handle = CmuxToastCenter(host: host).show(CmuxToast(id: "layout.resizeMode", message: "Snap"), in: window)
        defer { handle.dismiss() }
        let toast = try #require(Self.toastViews(in: window).first)
        #expect(toast.convert(toast.bounds, to: nil).minY < composer.maxY, "a hidden chat still held the toast up")

        workspace.isHidden = false
        // The move runs one main-actor turn after the change (`CmuxToastAvoidance.avoidanceChanged`).
        for _ in 0..<20 where toast.convert(toast.bounds, to: nil).minY < composer.maxY { await Task.yield() }
        #expect(toast.convert(toast.bounds, to: nil).minY >= composer.maxY + CmuxToastOverlayHost.avoidanceGap - 0.5,
                "the toast stayed over the composer after the chat showed again")
    }

    /// A chat moved straight to another window at the same window-relative frame: a toast already
    /// showing there moves above its composer, and the window it left stops avoiding it.
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

        // A toast in the destination window, which has no chat yet: it rests at the window's foot.
        let host = CmuxToastOverlayHost()
        let handle = CmuxToastCenter(host: host).show(CmuxToast(id: "layout.resizeMode", message: "Snap"), in: windows[1])
        defer { handle.dismiss() }
        let toast = try #require(Self.toastViews(in: windows[1]).first)
        #expect(toast.convert(toast.bounds, to: nil).minY < composer.maxY)

        destination.addSubview(view) // the same frame in the new window
        view.layoutSubtreeIfNeeded()
        #expect(view.convert(view.toastAvoidanceRect, to: nil) == composer)
        for _ in 0..<20 where toast.convert(toast.bounds, to: nil).minY < composer.maxY { await Task.yield() }
        #expect(toast.convert(toast.bounds, to: nil).minY >= composer.maxY + CmuxToastOverlayHost.avoidanceGap - 0.5,
                "the toast in the chat's new window stayed over its composer")
    }

    private static func toastViews(in window: NSWindow) -> [CmuxToastView] {
        guard let panel = WindowOverlayHost.existingHost(for: window)?.panel, let root = panel.contentView else { return [] }
        var found: [CmuxToastView] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let toast = view as? CmuxToastView { found.append(toast) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}

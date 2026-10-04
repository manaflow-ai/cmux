import AppKit
@testable import CmuxNextDesign
import Testing

/// The window's agent cursor layer (`WindowOverlayHost.agentCursorLayer`):
/// one y-down layer per window in content-view coordinates, above pages and
/// the sidebar, below modal overlays, never hit by the mouse. It lives in the
/// overlay panel while the panel is attached, else on top of the window's
/// content view.
@MainActor
@Suite(.serialized) struct WindowOverlayHostAgentCursorTests {
    init() { _ = NSApplication.shared }

    private func makeMain() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ForwardingContentView()
        window.orderFrontRegardless()
        return window
    }

    private func close(_ window: NSWindow) {
        window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
        window.close()
    }

    private func tooltip(_ host: WindowOverlayHost) -> OverlayHandle {
        host.present(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 24)),
                     options: .tooltip(at: NSRect(x: 100, y: 400, width: 40, height: 20)))
    }

    /// The view that carries the layer (its container).
    private func carrier(_ host: WindowOverlayHost) -> NSView? {
        host.agentCursorLayer.superlayer.flatMap { superlayer in
            [host.panel.contentView, host.window?.contentView].compactMap { $0 }
                .flatMap(\.subviews).first { $0.layer === superlayer }
        }
    }

    /// The layer's frame in content-view coordinates of the main window.
    private func frameInContent(_ host: WindowOverlayHost) -> NSRect? {
        guard let view = carrier(host), let content = host.window?.contentView else { return nil }
        let inView = NSRect(origin: .zero, size: host.agentCursorLayer.bounds.size)
        let inWindow: NSRect
        if view.window === host.window {
            inWindow = view.convert(inView, to: nil)
        } else {
            // The panel has the window's frame: panel coordinates are window coordinates.
            let inPanel = view.convert(inView, to: nil)
            guard let window = host.window else { return nil }
            inWindow = inPanel.offsetBy(dx: host.panel.frame.minX - window.frame.minX, dy: host.panel.frame.minY - window.frame.minY)
        }
        return content.convert(inWindow, from: nil)
    }

    @Test func theLayerIsLazyFlippedAndCoversTheContentView() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        let layer = host.agentCursorLayer
        #expect(layer === host.agentCursorLayer, "one layer per window")
        #expect(layer.isGeometryFlipped, "content coordinates are y-down")
        #expect(frameInContent(host) == main.contentView?.bounds)
        #expect(carrier(host)?.superview === main.contentView, "detached: on the content view")
        #expect(main.contentView?.subviews.last === carrier(host), "detached: the top subview")
    }

    @Test func theFrameFollowsResizeAndReattach() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer

        let first = tooltip(host)
        #expect(host.isPanelAttached)
        #expect(carrier(host)?.superview === host.panel.contentView, "attached: in the overlay panel")
        #expect(frameInContent(host) == main.contentView?.bounds)

        main.setFrame(NSRect(x: -30_000, y: -30_000, width: 1000, height: 700), display: false)
        #expect(host.agentCursorLayer.bounds.size == NSSize(width: 1000, height: 700))
        #expect(frameInContent(host) == main.contentView?.bounds, "after a resize while attached")

        first.dismiss()
        #expect(!host.isPanelAttached)
        main.setFrame(NSRect(x: -30_000, y: -30_000, width: 900, height: 650), display: false)
        #expect(carrier(host)?.superview === main.contentView)
        #expect(frameInContent(host) == main.contentView?.bounds, "after a resize while detached")

        let second = tooltip(host)
        defer { second.dismiss() }
        #expect(carrier(host)?.superview === host.panel.contentView)
        #expect(frameInContent(host) == main.contentView?.bounds, "after the reattach")
        #expect(host.agentCursorLayer.isGeometryFlipped)
    }

    @Test func theMouseNeverHitsTheCursor() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer
        let point = NSPoint(x: 400, y: 300)
        #expect(carrier(host)?.hitTest(point) == nil)
        if let content = main.contentView, let hit = content.hitTest(point) {
            #expect(hit !== carrier(host))
        }
        let handle = tooltip(host)
        defer { handle.dismiss() }
        #expect(carrier(host)?.hitTest(point) == nil)
    }

    @Test func theCursorIsAboveWindowOverlaysAndBelowAModal() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120)), options: .dialog())
        defer { dialog.dismiss() }
        let subviews = host.panel.contentView?.subviews ?? []
        guard let cursor = carrier(host).flatMap({ view in subviews.firstIndex { $0 === view } }),
              let window = subviews.firstIndex(where: { $0 === host.panel.windowContainer }),
              let modal = subviews.firstIndex(where: { $0 === host.panel.modalContainer }) else {
            Issue.record("the cursor, window and modal containers are all in the panel root")
            return
        }
        #expect(window < cursor && cursor < modal, "plane < pane < window < cursor < modal")
    }

    @Test func theCursorStaysTopmostWhileDetached() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer
        main.contentView?.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(main.contentView?.subviews.last === carrier(host), "a later subview does not cover the cursor")
        main.contentView?.addSubview(NSView(frame: .zero), positioned: .above, relativeTo: nil)
        #expect(main.contentView?.subviews.last === carrier(host))
    }

    /// `sortSubviews` and a `subviews =` assignment add nothing, so no add
    /// hook sees them: the root's layout pass puts the cursor back on top and
    /// reports that it had to.
    @Test func aReorderWithoutAnAddIsRepairedOnLayout() throws {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer
        let content = try #require(main.contentView)
        content.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(host.repairAgentCursorOrder() == false, "nothing to repair")
        content.subviews = content.subviews.reversed()
        #expect(content.subviews.last !== carrier(host))
        #expect(host.repairAgentCursorOrder() == true, "the reorder is caught")
        #expect(content.subviews.last === carrier(host))
        let handle = tooltip(host)
        defer { handle.dismiss() }
        #expect(host.repairAgentCursorOrder() == false, "attached: the panel order is the host's own")
    }

    @Test func tearDownRemovesTheCursor() {
        let main = makeMain()
        let host = WindowOverlayHost.host(for: main)
        let layer = host.agentCursorLayer
        close(main)
        _ = layer
        #expect(carrier(host) == nil, "neither the content view nor the panel carries the cursor after close")
    }
}

/// What `WindowRootView` does: tells the window's overlay host about new subviews.
private final class ForwardingContentView: NSView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let window { WindowOverlayHost.existingHost(for: window)?.contentViewDidAddSubview(subview) }
    }

    override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
        super.addSubview(view, positioned: place, relativeTo: otherView)
        if let window { WindowOverlayHost.existingHost(for: window)?.contentViewDidAddSubview(view) }
    }
}

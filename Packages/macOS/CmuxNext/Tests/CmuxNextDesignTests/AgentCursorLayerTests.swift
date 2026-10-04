import AppKit
@testable import CmuxNextDesign
import Testing

/// Agent cursors draw on one layer per main window (`WindowOverlayHost.agentCursorLayer`).
/// The layer covers the content view in content-view coordinates (y-down),
/// is above the layout, the sidebar and every page window, is below modal
/// overlays, and never takes the mouse.
@MainActor
@Suite(.serialized) struct AgentCursorLayerTests {
    init() { _ = NSApplication.shared }

    private func makeMain() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func makePage() -> NSWindow {
        let page = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 500), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    private func close(_ windows: NSWindow...) {
        for window in windows {
            window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
            window.close()
        }
    }

    /// The layer's rect in window coordinates, and the window it draws in.
    private func placement(of layer: CALayer, host: WindowOverlayHost) -> (rect: CGRect, window: NSWindow?) {
        let view = host.agentCursorView
        #expect(view.layer === layer.superlayer, "the cursor layer is the container's only content")
        #expect(layer.frame == view.bounds)
        return (view.convert(view.bounds, to: nil), view.window)
    }

    private func contentRect(of window: NSWindow) -> CGRect {
        let content = window.contentView!
        return content.convert(content.bounds, to: nil)
    }

    @Test func layerCoversTheContentViewAcrossResizeAndReattach() {
        let main = makeMain()
        let page = makePage()
        defer { close(main, page) }
        let host = WindowOverlayHost.host(for: main)
        let layer = host.agentCursorLayer
        #expect(host.agentCursorLayer === layer, "one layer per window")
        #expect(layer.isGeometryFlipped, "y-down, like the content view's callers")

        // No page window: the layer is in the window itself.
        var placed = placement(of: layer, host: host)
        #expect(placed.window === main)
        #expect(placed.rect == contentRect(of: main))

        // A page window shows: the panel attaches and the layer moves above the page.
        main.addChildWindow(page, ordered: .above)
        host.setPlanesWantPanel(true)
        placed = placement(of: layer, host: host)
        #expect(placed.window === host.panel)
        #expect(placed.rect == contentRect(of: main))

        main.setFrame(NSRect(x: -30_000, y: -30_000, width: 1000, height: 700), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: main)
        placed = placement(of: layer, host: host)
        #expect(placed.rect == contentRect(of: main), "follows a resize")
        #expect(placed.rect.size == CGSize(width: 1000, height: 700))

        // Detach, resize while detached, attach again.
        host.setPlanesWantPanel(false)
        placed = placement(of: layer, host: host)
        #expect(placed.window === main)
        main.setFrame(NSRect(x: -30_000, y: -30_000, width: 900, height: 650), display: false)
        host.setPlanesWantPanel(true)
        placed = placement(of: layer, host: host)
        #expect(placed.window === host.panel)
        #expect(placed.rect == contentRect(of: main), "follows a reattach")

        // y-down: the layer's origin is the content view's top-left.
        let top = layer.convert(CGPoint.zero, to: host.agentCursorView.layer)
        #expect(top.y == host.agentCursorView.bounds.height)
        host.setPlanesWantPanel(false)
    }

    @Test func layerNeverTakesTheMouse() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        let layer = host.agentCursorLayer
        let cursor = CALayer()
        cursor.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        layer.addSublayer(cursor)
        let center = host.agentCursorView.convert(CGPoint(x: 100, y: 100), to: nil)
        #expect(layer.hitTest(layer.convert(CGPoint(x: 15, y: 15), to: layer.superlayer)) == nil)
        #expect(host.agentCursorView.hitTest(CGPoint(x: 100, y: 100)) == nil)
        #expect(main.contentView?.hitTest(center) !== host.agentCursorView)
        host.setPlanesWantPanel(true)
        #expect(host.agentCursorView.hitTest(CGPoint(x: 100, y: 100)) == nil)
        #expect(host.interactiveRegions().isEmpty, "the cursor adds no interactive region to the panel")
        host.setPlanesWantPanel(false)
    }

    @Test func layerIsBelowAModalAndAboveWindowOverlays() {
        let main = makeMain()
        defer { close(main) }
        let host = WindowOverlayHost.host(for: main)
        _ = host.agentCursorLayer
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)), options: .dialog())
        defer { dialog.dismiss() }
        #expect(host.agentCursorView.window === host.panel, "a dialog attaches the panel and the cursor rides it")
        let order = host.panel.contentView?.subviews ?? []
        let cursor = order.firstIndex { $0 === host.agentCursorView }
        let modal = order.firstIndex { $0 === host.panel.modalContainer }
        let window = order.firstIndex { $0 === host.panel.windowContainer }
        #expect(cursor != nil && modal != nil && window != nil)
        if let cursor, let modal, let window {
            #expect(cursor < modal, "below modal dialogs and modal regions")
            #expect(cursor > window, "above tooltips and window overlays")
        }
    }
}

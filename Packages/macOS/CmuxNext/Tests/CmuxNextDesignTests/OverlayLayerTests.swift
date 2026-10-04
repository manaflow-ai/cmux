import AppKit
@testable import CmuxNextDesign
import Testing

/// Named layers, bottom to top: content (page windows) < pane overlays <
/// sidebar < window overlays < modal. The sidebar stays in the main window's
/// view tree, so it is an occluder: pages are masked under it and pane
/// overlays are clipped to their pane minus the sidebar.
@MainActor
@Suite(.serialized) struct OverlayLayerTests {
    init() { _ = NSApplication.shared }

    private func makeMain() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func makePage() -> NSWindow {
        let page = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 600), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        return page
    }

    @Test func layersOrderAndTheSidebarOccludesPaneOverlays() {
        let main = makeMain()
        let page = makePage()
        defer {
            main.childWindows?.forEach { main.removeChildWindow($0); $0.orderOut(nil) }
            main.close()
        }
        main.addChildWindow(page, ordered: .above)
        let host = WindowOverlayHost.host(for: main)
        let pane = NSRect(x: 0, y: 0, width: 800, height: 600)
        let sidebar = NSRect(x: 0, y: 0, width: 240, height: 600)

        let paneTip = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40)),
                                   options: OverlayOptions(kind: .tooltip, anchor: NSRect(x: 100, y: 300, width: 20, height: 20),
                                                           layer: .pane(clip: pane)))
        let toast = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40)), options: OverlayOptions(kind: .toast))
        host.setOccluder(id: "sidebar", rect: sidebar)

        // The fork re-shows the page: the order is page < host panel.
        main.removeChildWindow(page)
        main.addChildWindow(page, ordered: .above)
        WindowOverlayHost.childWindowsDidChange(of: main)
        #expect(host.isAbovePages)

        // Pages are masked under the sidebar (the layer gives these to the fork).
        #expect(host.occluderRects == [sidebar])
        // The pane overlay is clipped to its pane minus the sidebar.
        let visible = host.visibleRegion(of: paneTip)
        #expect(!visible.contains { $0.intersects(sidebar) }, "nothing of the pane overlay shows over the sidebar")
        #expect(visible.contains { $0.contains(NSPoint(x: 300, y: 290)) }, "it still shows beside the sidebar")
        // Window overlays are above pane overlays; the modal layer is above both.
        #expect(host.layerIndex(of: toast) > host.layerIndex(of: paneTip))
        let dialog = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)), options: .dialog())
        #expect(dialog.options.effectiveLayer == .modal)
        #expect(host.layerIndex(of: dialog) > host.layerIndex(of: toast))

        host.setOccluder(id: "sidebar", rect: nil)
        #expect(host.occluderRects.isEmpty)
        for handle in [dialog, toast, paneTip] { handle.dismiss() }
    }

    @Test func layerDefaultsFollowTheKind() {
        #expect(OverlayOptions(kind: .dialog).effectiveLayer == .modal)
        #expect(OverlayOptions(kind: .toast).effectiveLayer == .window)
        #expect(OverlayOptions(kind: .popover).effectiveLayer == .window)
        let clip = NSRect(x: 0, y: 0, width: 10, height: 10)
        #expect(OverlayOptions(kind: .tooltip, layer: .pane(clip: clip)).effectiveLayer == .pane(clip: clip))
    }
}

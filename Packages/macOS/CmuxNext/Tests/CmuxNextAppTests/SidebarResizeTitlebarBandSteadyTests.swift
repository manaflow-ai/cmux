import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Dragging the sidebar's width leaves the titlebar band (the sidebar toggle, Back, Forward) where it
/// is, to the pixel (#48495). The band's presence was the sidebar's laid-out frame width over the
/// width the drag set: the drag sets fractional widths from the pointer, Auto Layout rounds the frame
/// to whole pixels, so the share flickered just under 1 and the band's origin, width and button slots
/// moved by a pixel on every other step. The sidebar's +, floored at the band's edge, read the panel's
/// origin from the rounded bounds less the fractional panel width and moved a pixel on a tie.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarResizeTitlebarBandSteadyTests {
    func root() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        settle(root)
        return (window, root)
    }

    func settle(_ root: WindowRootView) {
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    /// The band's and its buttons' frames in the window.
    func bandFrames(_ root: WindowRootView) -> [CGRect] {
        let band = root.toolbarBand
        return [band.convert(band.bounds, to: nil)]
            + [band.sidebarToggle, band.backButton, band.forwardButton].map { band.convert($0.frame, to: nil) }
    }

    @Test func fractionalDragStepsLeaveTheBandPixelFixed() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        #expect(!container.model.isHidden)
        let rest = bandFrames(root)
        #expect(root.toolbarBand.presence == 1)
        container.handleDrag(.began)
        // Trackpad and mouse deltas land between pixels at any backing scale; both directions.
        for step in 1...24 {
            let dx = CGFloat(step) * 1.13 * (step.isMultiple(of: 2) ? 1 : -1)
            container.handleDrag(.changed(dx))
            settle(root)
            #expect(container.onScreenShare == 1, "step \(step): share \(container.onScreenShare)")
            #expect(root.toolbarBand.presence == 1, "step \(step): presence \(root.toolbarBand.presence)")
            #expect(root.toolbarBand.alphaValue == 1, "step \(step)")
            #expect(bandFrames(root) == rest, "step \(step) dx \(dx): \(bandFrames(root)) != \(rest)")
            // The + is floored at the band's edge only when the sidebar is too narrow for it; at these
            // widths it rides its column and is never shifted by a rounding error in the panel's origin.
            #expect(container.sidebarView.titlebarRowShift == 0, "step \(step): + shifted \(container.sidebarView.titlebarRowShift)")
        }
        container.handleDrag(.ended)
        settle(root)
        #expect(bandFrames(root) == rest)
    }

    /// The share still follows the slide: hidden is 0, shown is 1 (the band opens and closes with it).
    @Test func theShareStillFollowsHideAndShow() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        container.restore(width: container.model.width, presentation: .hidden)
        settle(root)
        #expect(container.onScreenShare == 0)
        #expect(root.toolbarBand.presence == 0)
        container.restore(width: container.model.width, presentation: .shown)
        settle(root)
        #expect(container.onScreenShare == 1)
        #expect(root.toolbarBand.presence == 1)
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Collapsing the sidebar slides its titlebar row's + (New Workspace) with the sidebar's edge. It
/// used to slide over the toolbar band (toggle, Back, Forward) and the traffic lights to the window's
/// edge in a few frames, so it read as jumping left. Every frame of the slide now keeps the + right of
/// the band's edge on screen; the sidebar's edge closes over it there.
@MainActor @Suite(.closesItsWindows, .serialized) struct SidebarPlusSlideTests {
    func root() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    /// The + in window coordinates, and the part of it the sidebar's edge leaves on screen.
    func plus(_ root: WindowRootView) -> (frame: CGRect, shown: CGRect) {
        let button = root.sidebar.sidebarView.newButton
        let frame = button.convert(button.bounds, to: nil)
        return (frame, frame.intersection(root.sidebar.convert(root.sidebar.bounds, to: nil)))
    }

    @Test func thePlusNeverSlidesOverTheToolbarBandWhileTheSidebarCollapses() {
        let (window, root) = root()
        defer { window.close() }
        let width = root.sidebar.model.width
        let resting = plus(root).frame
        #expect(resting.width > 0)
        var shownFrames = 0
        // The width slide's frames, open to closed: the band's presence follows the same width.
        for step in stride(from: 20, through: 0, by: -1) {
            root.sidebar.widthConstraint.constant = width * CGFloat(step) / 20
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            let band = root.toolbarBand.convert(root.toolbarBand.bounds, to: nil)
            let (frame, shown) = plus(root)
            guard shown.width > 0.5 else { continue }
            shownFrames += 1
            #expect(frame.minX >= band.maxX + Metrics.space2 - 0.5,
                    "step \(step): the + at x \(frame.minX) is over the toolbar band ending at \(band.maxX)")
        }
        #expect(shownFrames > 2)
        // Opened again, the + is back where it rests.
        root.sidebar.widthConstraint.constant = width
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        #expect(abs(plus(root).frame.minX - resting.minX) < 0.5)
    }
}

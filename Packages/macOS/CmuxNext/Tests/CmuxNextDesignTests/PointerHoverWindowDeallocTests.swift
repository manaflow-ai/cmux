import AppKit
@testable import CmuxNextDesign
import Testing

/// p1361 follow-up: a window that deallocates tears its views down, and a view that refreshes
/// its hover there (the layout root settles its motion in `viewWillMove(toWindow: nil)`, and the
/// strip scrollbar refreshes its `PointerHover`) still reports the dying window as its window.
/// The runtime aborts on any weak reference to an object in deallocation ("Cannot form weak
/// reference to instance ... of class NSWindow"); it crashed PaneCloseMotionTests and
/// PaneHorizontalScrollClaimTests, and can crash the app when a window closes. The hover owner
/// keeps no window now, but a refresh during the teardown still must not form a weak reference
/// to the dying window or its views, nor read a pointer from it (`isBeingDeallocated`).
@MainActor
struct PointerHoverWindowDeallocTests {
    /// Refreshes its hover as it leaves its window, as the strip scrollbar does in a teardown.
    private final class RefreshingView: NSView {
        var hover: PointerHover?
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { hover?.refresh() }
        }
    }

    @Test func aHoverRefreshInsideAWindowDeallocDoesNotCrash() {
        let view = RefreshingView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        // Made before the view is in a window, so its first refresh with a window is the teardown's.
        let hover = PointerHover(view)
        view.hover = hover
        weak var released: NSWindow?
        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(view)
            released = window
        }
        #expect(released == nil, "the window deallocated")
        #expect(view.window == nil)
        #expect(!hover.isHovering)
        // The target is still usable after the teardown.
        hover.refresh()
        #expect(!hover.isHovering)
    }
}

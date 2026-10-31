import AppKit
@testable import CmuxNextLayout
import Testing

/// A press that starts a window resize focuses no pane.
///
/// The layout's local mouse-down monitor (`LayoutRootView.handleMonitored`) focuses the pane under
/// every press inside its bounds, before AppKit dispatches the press. AppKit takes a press at the
/// window's edge or corner, inside its frame, as a window resize: no view gets it. The monitor still
/// focused the pane under it, so after a person resized the window by its bottom-right corner the
/// keys went to the pane in that corner, not the one they were typing in (journey r3-after-switch
/// failed 4 of 4 on v2.2.11-opt, cmux-ad P0 2026-10-31).
@MainActor
struct WindowResizePressKeepsFocusTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("left"), b: .leaf("right")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "left")
            root = LayoutRootView(model: model, contentProvider: provider)
            // The shell window's style (WindowController): titled, resizable, full-size content.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        /// A press at `point` (window base coordinates), as the monitor sees it before AppKit dispatches it.
        func press(at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: 1)!
            _ = root.handleMonitored(event)
        }

        /// What AppKit's own hit test gives at `point`: the view a press there is delivered to.
        func hit(at point: CGPoint) -> String {
            guard let frameView = window.contentView?.superview, let view = frameView.hitTest(frameView.convert(point, from: nil)) else {
                return "nil"
            }
            let place = view === frameView ? "frame" : view.isDescendant(of: root) ? "layout" : "other"
            return "\(type(of: view))(\(place))"
        }

        var size: CGSize { window.frame.size }
    }

    @Test func aPressInTheBottomRightResizeCornerLeavesTheFocus() {
        let harness = Harness()
        let corner = CGPoint(x: harness.size.width - 1, y: 1)
        harness.press(at: corner)
        #expect(harness.model.focusedPane == "left",
                "a press in the window's resize corner focused \(String(describing: harness.model.focusedPane)); AppKit's hit test there: \(harness.hit(at: corner))")
    }

    @Test func aPressInsideAPaneStillFocusesIt() {
        let harness = Harness()
        harness.press(at: CGPoint(x: harness.size.width * 0.75, y: harness.size.height / 2))
        #expect(harness.model.focusedPane == "right")
    }

    /// Not a check: prints where AppKit's hit test sends presses near the window's edges, for the record.
    @Test func reportsAppKitHitTestNearTheEdges() {
        let harness = Harness()
        let (w, h) = (harness.size.width, harness.size.height)
        for inset in [0.0, 1, 2, 3, 4, 5, 6, 8, 12] {
            let corner = harness.hit(at: CGPoint(x: w - 1 - inset, y: 1 + inset))
            let right = harness.hit(at: CGPoint(x: w - 1 - inset, y: h / 2))
            let bottom = harness.hit(at: CGPoint(x: w / 2, y: 1 + inset))
            let left = harness.hit(at: CGPoint(x: 1 + inset, y: h / 2))
            print("P0FD-HIT inset \(inset): corner \(corner) right \(right) bottom \(bottom) left \(left)")
        }
    }
}

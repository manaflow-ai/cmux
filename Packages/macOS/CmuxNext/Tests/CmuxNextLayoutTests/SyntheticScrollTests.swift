import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// A synthesized trackpad scroll (`debug.mouse`) carries no window, so its
/// `locationInWindow` is a screen point and the layout's event monitor never
/// sees it. `LayoutRootView.handleScroll(_:locationInWindow:)` routes it at
/// the window point the caller knows, exactly like a real one (cx-1ti8).
@MainActor @Suite(.serialized)
struct SyntheticScrollTests {
    private func makeRoot() -> (LayoutRootView, NSWindow) {
        let columns = ["a", "b", "c", "d"].map { id in
            LayoutColumn(id: ColumnID("c\(id)"), width: 0.5, root: .leaf(PaneID(id)))
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns(columns))],
                                activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        let view = LayoutRootView(model: model, contentProvider: ScrollStubProvider.shared)
        view.context.reduceMotionOverride = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// A trackpad scroll event with no window, as `debug.mouse` makes it.
    private func scroll(dx: Double, phase: Int64) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        return NSEvent(cgEvent: cg)!
    }

    @Test func aWindowlessTrackpadScrollMovesTheStrip() {
        let (view, window) = makeRoot()
        defer { window.close() }
        let screen = view.screenViews["s"]!
        let point = NSPoint(x: 500, y: 300)
        #expect(screen.scroll.value == 0)
        #expect(view.handleScroll(scroll(dx: 0, phase: 1), locationInWindow: point) == false, "a began with no motion stays undecided")
        #expect(view.handleScroll(scroll(dx: -120, phase: 2), locationInWindow: point))
        #expect(view.handleScroll(scroll(dx: -120, phase: 2), locationInWindow: point))
        #expect(screen.scroll.value > 100, "the strip follows the gesture (\(screen.scroll.value))")
        #expect(view.handleScroll(scroll(dx: 0, phase: 4), locationInWindow: point))
    }

    /// Outside the layout the event is not consumed (the caller delivers it
    /// to the view under the point).
    @Test func aScrollOutsideTheLayoutIsNotConsumed() {
        let (view, window) = makeRoot()
        defer { window.close() }
        let outside = NSPoint(x: 2000, y: 300)
        #expect(!view.handleScroll(scroll(dx: 0, phase: 1), locationInWindow: outside))
        #expect(!view.handleScroll(scroll(dx: -120, phase: 2), locationInWindow: outside))
    }
}

private final class ScrollStubProvider: LayoutPaneContentProvider {
    static let shared = ScrollStubProvider()
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

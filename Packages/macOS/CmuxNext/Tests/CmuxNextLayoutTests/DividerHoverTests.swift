import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// Divider hover is a function of where the pointer is now and where the
/// dividers are now (cx-ww20). Scrolling the strip moves the dividers under
/// a still pointer: no mouse event arrives, and the hover must still follow.
@MainActor @Suite(.serialized)
struct DividerHoverTests {
    /// The pointer, injected: tests never read the real mouse.
    final class Pointer { var location: NSPoint? }

    private func makeRoot(_ pointer: Pointer) -> (LayoutRootView, NSWindow) {
        let columns = ["a", "b", "c", "d"].map { id in
            LayoutColumn(id: ColumnID("c\(id)"), width: 0.5, root: .leaf(PaneID(id)))
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns(columns))],
                                activeScreenID: "s", focusedPane: "a")
        model.followsDesignMetrics = false
        let view = LayoutRootView(model: model, contentProvider: HoverStubProvider.shared)
        view.context.reduceMotionOverride = true
        view.context.hoverPointer = { (_: NSWindow) -> NSPoint? in pointer.location }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func edges(_ screen: ScreenContentView) -> [DividerHandleView] {
        screen.subviews.compactMap { $0 as? DividerHandleView }.filter {
            if case .columnEdge = $0.kind { true } else { false }
        }
    }

    private func enter(_ view: DividerHandleView) {
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseEntered(with: event)
    }

    /// The pointer rests on a column edge; the strip scrolls with no mouse
    /// event. The edge that moved away clears, and only an edge that is now
    /// under the pointer is lit.
    @Test func scrollingTheStripUnderAStillPointerMovesTheHover() {
        let pointer = Pointer()
        let (view, window) = makeRoot(pointer)
        defer { window.close() }
        let screen = view.screenViews["s"]!
        let first = edges(screen).min { $0.frame.minX < $1.frame.minX }!
        let point = NSPoint(x: first.frame.midX, y: first.frame.midY)
        pointer.location = screen.convert(point, to: nil)
        enter(first)
        #expect(first.isHovered)

        screen.beginUserScroll()
        screen.userScroll(deltaX: -120, timestamp: 1)
        #expect(!first.frame.contains(point), "the edge moved away from the pointer")
        for edge in edges(screen) {
            #expect(edge.isHovered == (!edge.isHidden && edge.frame.contains(point)), "edge \(edge.kind)")
        }
    }

    /// A hover reported by a page's click-catching panel does not outlive the
    /// divider leaving the pointer either.
    @Test func aForwardedHoverClearsWhenTheDividerScrollsAway() {
        let pointer = Pointer()
        let (view, window) = makeRoot(pointer)
        defer { window.close() }
        let screen = view.screenViews["s"]!
        let first = edges(screen).min { $0.frame.minX < $1.frame.minX }!
        let point = NSPoint(x: first.frame.midX, y: first.frame.midY)
        pointer.location = screen.convert(point, to: nil)
        view.setDividerHovered(first.kind.mouseAreaID, true)
        #expect(first.isHovered)

        screen.beginUserScroll()
        screen.userScroll(deltaX: -120, timestamp: 1)
        #expect(!first.isHovered)
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A layout change removes the handle under a drag (its column closed):
    /// the mouse-up never reaches it, so the owner ends the drag. The model
    /// leaves gesture mode and the display link comes to rest (it spun).
    @Test func removingTheHandleMidDragEndsTheDrag() async {
        let pointer = Pointer()
        let (view, window) = makeRoot(pointer)
        defer { window.close() }
        let screen = view.screenViews["s"]!
        let edge = edges(screen).first { $0.kind == .columnEdge("ca") }!
        let point = screen.convert(NSPoint(x: edge.frame.midX, y: edge.frame.midY), to: nil)
        edge.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1)!)
        #expect(view.model.isGestureActive)
        #expect(screen.activeDrag != nil)

        let rest = ["b", "c", "d"].map { id in LayoutColumn(id: ColumnID("c\(id)"), width: 0.5, root: .leaf(PaneID(id))) }
        view.model.apply(screens: [LayoutScreen(id: "s", name: "", layout: .columns(rest))])
        await settle { !edges(screen).contains { $0.kind == .columnEdge("ca") } }
        #expect(edge.superview == nil)
        #expect(screen.activeDrag == nil)
        #expect(!view.model.isGestureActive)
        var frames = 0
        while frames < 600, view.driver.onFrame?(1.0 / 60) == true { frames += 1 }
        #expect(frames < 600, "the display link comes to rest")
    }
}

private final class HoverStubProvider: LayoutPaneContentProvider {
    static let shared = HoverStubProvider()
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// A column-edge drag (cx-ww20, "resizing is very buggy"): the column being
/// resized is the camera's anchor, so its leading edge stays put on screen
/// and its trailing edge follows the pointer exactly, whichever column has
/// focus. The scroll must not move the strip under the drag: the drag reads
/// the pointer in strip space, so a moving strip would feed back into the
/// width and make it jump.
@MainActor @Suite(.serialized)
struct ColumnResizeAnchorTests {
    private func makeRoot(focus: PaneID) -> (LayoutRootView, NSWindow) {
        let columns = ["a", "b", "c", "d"].map { id in
            LayoutColumn(id: ColumnID("c\(id)"), width: 0.4, root: .leaf(PaneID(id)))
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .columns(columns))],
                                activeScreenID: "s", focusedPane: focus)
        model.followsDesignMetrics = false
        let view = LayoutRootView(model: model, contentProvider: ResizeStubProvider.shared)
        view.context.reduceMotionOverride = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func runToRest(_ view: LayoutRootView) {
        for _ in 0..<600 where view.driver.onFrame?(1.0 / 60) == true {}
    }

    @Test(arguments: ["a", "b"] as [PaneID])
    func theResizedColumnKeepsItsLeadingEdgeAndFollowsThePointer(focus: PaneID) async {
        let (view, window) = makeRoot(focus: focus)
        defer { window.close() }
        let screen = view.screenViews["s"]!
        runToRest(view)
        let start = view.frame(of: "a")!
        let edge = screen.subviews.compactMap { $0 as? DividerHandleView }.first { $0.kind == .columnEdge("ca") }!
        let grab = screen.convert(NSPoint(x: edge.frame.midX, y: edge.frame.midY), to: nil)
        screen.handleDrag(kind: edge.kind, event: .began(grab))
        for step in 1...5 {
            let pointer = NSPoint(x: grab.x + CGFloat(step) * 20, y: grab.y)
            screen.handleDrag(kind: edge.kind, event: .moved(pointer))
            await settle { abs(view.frame(of: "a")!.width - (start.width + CGFloat(step) * 20)) < 1 }
            runToRest(view)
            let now = view.frame(of: "a")!
            #expect(abs(now.minX - start.minX) < 0.5, "focus \(focus) step \(step): the leading edge stays (\(now.minX) vs \(start.minX))")
            #expect(abs(now.maxX - (start.maxX + CGFloat(step) * 20)) < 1, "focus \(focus) step \(step): the edge follows the pointer")
        }
        screen.handleDrag(kind: edge.kind, event: .ended(NSPoint(x: grab.x + 100, y: grab.y)))
    }
}

private final class ResizeStubProvider: LayoutPaneContentProvider {
    static let shared = ResizeStubProvider()
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

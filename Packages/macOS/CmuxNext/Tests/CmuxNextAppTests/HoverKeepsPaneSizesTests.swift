import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Hovering never resizes a pane (Leo 2026-11-25, from his NIGHTLY: "also the pane got resized for some reason
/// visually ... i hoered over the top tabs maybe but that is fine in other places").
///
/// The pointer's whole path over a split (the top tab row, both panes, across the divider) goes through every
/// handler the layout has for a move (`mouseMoved`, pointer travel, focus follows mouse, on and off), and the split's
/// ratio and each pane's frame stay what they were. Only a press on a divider moves it. The page side of the same
/// report (a hover card's picture re-laid out the on-screen chat, cmux#56141) is held by
/// `PageWebViewEngineNeutralTests.noPassivePictureAsksForAViewportEmulation` and `CEFThumbnailParamsTests`.
@MainActor @Suite(.closesItsWindows)
struct HoverKeepsPaneSizesTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(followsMouse: Bool) {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("left"), b: .leaf("right")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "left")
            model.focusFollowsMouseOverride = followsMouse
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            let content = NSView()
            window.contentView = content
            root.frame = content.bounds
            root.autoresizingMask = [.width, .height]
            content.addSubview(root)
            root.layoutSubtreeIfNeeded()
        }

        var ratio: Double? { model.screens.first?.layout.ratio(of: "x") }
        var frames: [CGRect?] { [root.frame(of: "left"), root.frame(of: "right")] }

        /// One pointer move to `point` (window base coordinates), as AppKit delivers it to the layout.
        func hover(_ point: CGPoint, travel: CGFloat) {
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                root.mouseMoved(with: event)
            }
            root.handlePointerTravel(travel)
            _ = root.focusPaneForPointerHover(at: point)
            root.layoutSubtreeIfNeeded()
        }

        func close() { window.closeAfterTest() }
    }

    /// The path: along the top row (where each pane's tab strip sits), back along the middle, and over the divider.
    static func path(width: CGFloat, height: CGFloat) -> [CGPoint] {
        let xs = stride(from: CGFloat(2), through: width - 2, by: 7).map { $0 }
        let top = xs.map { CGPoint(x: $0, y: height - 14) }
        let middle = xs.reversed().map { CGPoint(x: $0, y: height / 2) }
        let divider = stride(from: CGFloat(4), through: height - 4, by: 11).map { CGPoint(x: width / 2, y: $0) }
        return top + middle + divider + top
    }

    @Test(arguments: [false, true])
    func hoveringTheTabRowAndPanesKeepsEveryPaneSize(followsMouse: Bool) throws {
        let harness = Harness(followsMouse: followsMouse)
        defer { harness.close() }
        let ratio = try #require(harness.ratio)
        let frames = harness.frames
        try #require(frames.allSatisfy { ($0?.width ?? 0) > 100 }, "both panes must show for this test to mean anything")
        let size = harness.root.bounds.size
        for (step, point) in Self.path(width: size.width, height: size.height).enumerated() {
            harness.hover(point, travel: CGFloat(7 + step % 5))
        }
        #expect(harness.ratio == ratio, "a hover moved the split")
        #expect(harness.frames == frames, "a hover resized a pane")
    }
}

import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Dragging a split divider (cx-piioc): near a half, a third, two thirds or the equal share of its
/// chain it snaps there, so panes line up without pixel hunting; past the snap distance it follows
/// the pointer.
@MainActor
@Suite(.closesItsWindows)
struct DividerSnapTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ tree: SplitNode) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        func ratio(_ split: SplitID) -> Double? { model.screens.first?.layout.ratio(of: split) }

        /// Presses `split`'s divider, drags it so its leading side would be `fraction` of the
        /// split's room plus `offset` points, and releases.
        func drag(_ split: SplitID, toFraction fraction: Double, offset: CGFloat) {
            guard let screen, let divider = screen.geometry.dividers.first(where: { $0.id == split }),
                  let handle = screen.dividerViews[.split(split)] else {
                Issue.record("no divider \(split)")
                return
            }
            let available = divider.container.width - screen.context.style.dividerThickness
            let current = divider.frame.minX - divider.container.minX
            let start = CGPoint(x: divider.frame.midX + screen.stripShift, y: divider.frame.midY)
            let delta = available * fraction + offset - current
            let from = screen.convert(start, to: nil)
            let to = screen.convert(CGPoint(x: start.x + delta, y: start.y), to: nil)
            handle.mouseDown(with: event(.leftMouseDown, from))
            handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: to.y)))
            handle.mouseDragged(with: event(.leftMouseDragged, to))
            handle.mouseUp(with: event(.leftMouseUp, to))
        }

        private func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    @Test func aDividerNearTheMiddleSnapsToHalfAndFarFromItFollowsThePointer() throws {
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2")))
        defer { screen.window.closeAfterTest() }
        screen.drag("x", toFraction: 0.5, offset: 4)
        #expect(screen.ratio("x") == 0.5)

        screen.drag("x", toFraction: 0.5, offset: 40)
        let free = try #require(screen.ratio("x"))
        #expect(free > 0.52 && free < 0.56)

        screen.drag("x", toFraction: 2.0 / 3, offset: -5)
        #expect(screen.ratio("x") == 2.0 / 3)
    }

    @Test func aDividerSnapsToTheEqualShareOfItsChain() {
        // One pane beside three: equal panes put the outer divider at a quarter.
        let three: SplitNode = .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"),
                                      b: .split("z", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4")))
        let screen = Screen(.split("x", axis: .horizontal, ratio: 0.4, a: .leaf("p1"), b: three))
        defer { screen.window.closeAfterTest() }
        screen.drag("x", toFraction: 0.25, offset: 5)
        #expect(screen.ratio("x") == 0.25)
    }
}

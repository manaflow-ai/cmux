import AppKit
@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextTabs
import Testing

/// Dragging a pane by its tab bar's empty space onto another pane swaps the two (cx-8bv1j); a drop
/// back on its own pane does nothing. The tab bar's tabs keep their own drag.
@MainActor
struct PaneSwapDragTests {
    final class Panes: LayoutPaneContentProvider {
        var strips: [PaneID: TabStripView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let strip = TabStripView(model: TabStripModel(tabs: [TabItem(id: TabID("\(pane.rawValue)-tab"), title: "zsh")]))
            // The test window has no title bar row; empty space must not move it either way.
            strip.dragsWindowFromEmptySpace = false
            strips[pane] = strip
            return strip
        }
    }

    final class Window {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var swaps: [(PaneID, PaneID)] = []
        private var drags: [PaneSwapDrag] = []

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            for (pane, strip) in provider.strips {
                drags.append(PaneSwapDrag(strip: strip, pane: pane, layout: { [root] in root },
                                          swap: { [unowned self] in swaps.append(($0, $1)) }))
            }
        }

        /// A point in `pane`'s strip past its tabs and + button, in window coordinates.
        func emptyStripPoint(_ pane: PaneID) throws -> CGPoint {
            let strip = try #require(provider.strips[pane])
            let point = CGPoint(x: strip.bounds.maxX - 40, y: strip.bounds.midY)
            #expect(strip.titlebarHit(at: point) == .empty)
            return strip.convert(point, to: nil)
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        func drag(from start: CGPoint, to end: CGPoint) {
            send(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            send(.leftMouseUp, end)
        }

        private func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }
    }

    @Test func draggingAPaneByItsTabBarOntoAnotherSwapsThem() throws {
        let window = Window()
        window.drag(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }

    @Test func aDropOnItsOwnPaneSwapsNothing() throws {
        let window = Window()
        window.drag(from: try window.emptyStripPoint("p2"), to: try window.center("p2"))
        #expect(window.swaps.isEmpty)
    }
}

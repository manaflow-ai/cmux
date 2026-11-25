import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Dragging a pane by its tab bar's empty space onto another pane swaps the two (cx-8bv1j); a drop
/// back on its own pane does nothing. The tab bar's tabs keep their own drag.
@MainActor
@Suite(.closesItsWindows)
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
            // Gesture recognizers only see the events of a window on screen.
            window.orderFrontRegardless()
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

        /// Presses at `start` and drags to `end` without releasing; `release()` ends it.
        func hold(from start: CGPoint, to end: CGPoint) {
            send(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            lastHeld = end
        }

        private var lastHeld: CGPoint = .zero
        func release() { send(.leftMouseUp, lastHeld) }

        private func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            window.sendEvent(event)
        }
    }

    @Test func draggingAPaneByItsTabBarOntoAnotherSwapsThem() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
        window.drag(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }

    /// The press decides, not where the pan begins: a drag from a tab is the tab's own drag.
    @Test func aDragFromATabSwapsNothing() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
        let strip = try #require(window.provider.strips["p1"])
        let cell = try #require(strip.cells[TabID("p1-tab")])
        let tab = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        window.drag(from: strip.convert(tab, to: nil), to: try window.center("p2"))
        #expect(window.swaps.isEmpty)
    }

    @Test func aDropOnItsOwnPaneSwapsNothing() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
        window.drag(from: try window.emptyStripPoint("p2"), to: try window.center("p2"))
        #expect(window.swaps.isEmpty)
    }

    /// Lawrence 2026-10-19 (u2814): "Mouse down to focus tab is still not implemented." The strip
    /// selects on the press, but the pane-swap pan recognizer tried every press, tabs included, and
    /// AppKit held the mouse-down from the strip until the recognizer failed at the release: every
    /// pane tab switched on mouse-up. A press on a tab must reach the strip at once.
    @Test func aPressOnATabSelectsItBeforeTheRelease() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("a"), title: "a"), TabItem(id: TabID("b"), title: "b")],
                                  selectedID: TabID("a"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        var intents: [TabStripIntent] = []
        model.intentHandler = { intents.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        // Gesture recognizers only see the events of a window on screen.
        window.orderFrontRegardless()
        defer { window.closeAfterTest() }
        strip.layoutSubtreeIfNeeded()
        let drag = PaneSwapDrag(strip: strip, pane: "p1", layout: { nil }, swap: { _, _ in })
        defer { withExtendedLifetime(drag) {} }
        let cell = try #require(strip.cells[TabID("b")])
        let point = strip.convert(strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip), to: nil)
        func send(_ type: NSEvent.EventType) throws {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
        }
        try send(.leftMouseDown)
        #expect(intents.contains(.select(TabID("b"))), "the press did not select the tab before the release: \(intents)")
        try send(.leftMouseUp)
        #expect(intents.filter { $0 == .select(TabID("b")) }.count == 1, "one click selects the tab once: \(intents)")
    }

    /// The target pane previews as the pane drop zones do (a fill over its body), not as the 2 pt
    /// tab bar caret: a pane drag and a tab drag share one preview (drop-zones DESIGN.md).
    @Test func theTargetPanePreviewsItsBody() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        let shown = window.root.highlight.destinationRect
        let pane = try #require(window.root.frame(of: "p2"))
        window.release()
        #expect(shown.width > pane.width / 2)
        #expect(shown.height > pane.height / 2)
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }
}

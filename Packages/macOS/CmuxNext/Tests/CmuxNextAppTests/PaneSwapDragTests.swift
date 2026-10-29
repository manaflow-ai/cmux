import AppKit
@testable import CmuxNextApp
import CmuxNextInput
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Dragging a pane by its tab bar's empty space onto another pane swaps the two (cx-8bv1j); a drop
/// back on its own pane does nothing. The tab bar's tabs keep their own drag. With feature
/// `pointerFrameDrags` the drag previews on a frame interval's first move and once at the frame;
/// with it off every move previews.
@MainActor
struct PaneSwapDragTests {
    final class Panes: LayoutPaneContentProvider {
        var strips: [PaneID: TabStripView] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let strip = TabStripView.testing(model: TabStripModel(tabs: [TabItem(id: TabID("\(pane.rawValue)-tab"), title: "zsh")]))
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
        /// The drags' input tap: Escape reaches a drag through it.
        let tap = InputEventTap()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var swaps: [(PaneID, PaneID)] = []
        private(set) var drags: [PaneID: PaneSwapDrag] = [:]
        /// The drags' frame-aligned input, when the window has it (feature `pointerFrameDrags`): a drag's trailing
        /// moves preview when the test calls `frames.frame()`. Nil: every move previews.
        let frames: FrameInputTestRig?
        /// The drag moves' clock: each move is one 1/256 s step after the last, from 1000 s.
        private var moveTime = 1000 - 1.0 / 256

        /// `frames`: the drags go through the layout's frame-aligned input. `resampled`: the preview's pointer
        /// is resampled at the frame.
        init(frames: FrameInputTestRig? = nil, resampled: Bool = false) {
            self.frames = frames
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window.contentView = root
            // Gesture recognizers only see the events of a window on screen.
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            root.setDragInput(frames: frames?.coalescers, resampler: { resampled ? DragResampler() : nil })
            root.context.reduceMotionOverride = false
            for (pane, strip) in provider.strips {
                drags[pane] = PaneSwapDrag(strip: strip, pane: pane, input: tap, layout: { [root] in root },
                                           swap: { [unowned self] in swaps.append(($0, $1)) },
                                           now: { [unowned self] in
                                               moveTime += 1.0 / 256
                                               return moveTime
                                           })
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

        /// Presses at `start` and drags to `end` without releasing; `release()` ends it. With `frame`,
        /// a display frame follows the moves (the preview follows the frame's latest move).
        func hold(from start: CGPoint, to end: CGPoint, frame: Bool = true) {
            send(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            lastHeld = end
            if frame { frames?.frame() }
        }

        private var lastHeld: CGPoint = .zero
        func release() { send(.leftMouseUp, lastHeld) }

        /// Presses at `start` and drags to `end` in eight moves, one frame after every three, without releasing.
        func holdInFrames(from start: CGPoint, to end: CGPoint) {
            send(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                if step % 3 == 0 { frames?.frame() }
            }
            frames?.frame()
            lastHeld = end
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
        defer { window.window.orderOut(nil) }
        window.drag(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
        #expect(window.tap.subscriberCount(.key, stage: .intercept) == 0, "the drop left the drag's Escape intercept")
    }

    /// Escape cancels a pane drag through the input tap: the tap stops the key, the
    /// preview goes, the release swaps nothing, and the drag's Escape intercept lives for the drag only.
    @Test func escapeCancelsTheDragThroughTheTapAndDropsItsIntercept() throws {
        let window = Window()
        defer { window.window.orderOut(nil) }
        #expect(window.tap.subscriberCount(.key, stage: .intercept) == 0, "an intercept before any drag")
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        #expect(window.tap.subscriberCount(.key, stage: .intercept) == 1, "the drag did not watch Escape")
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                  isARepeat: false, keyCode: 0))
        #expect(window.tap.send(other) == .pass, "the drag took a key that is not Escape")
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                   windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(window.tap.send(escape) == .consume, "Escape went on to a responder")
        #expect(window.tap.subscriberCount(.key, stage: .intercept) == 0, "Escape left the drag's intercept")
        window.release()
        #expect(window.swaps.isEmpty, "the release after Escape swapped \(window.swaps)")
        #expect(window.tap.subscriberCount(.key, stage: .intercept) == 0)
    }

    /// The press decides, not where the pan begins: a drag from a tab is the tab's own drag.
    @Test func aDragFromATabSwapsNothing() throws {
        let window = Window()
        defer { window.window.orderOut(nil) }
        let strip = try #require(window.provider.strips["p1"])
        let cell = try #require(strip.cells[TabID("p1-tab")])
        let tab = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        window.drag(from: strip.convert(tab, to: nil), to: try window.center("p2"))
        #expect(window.swaps.isEmpty)
    }

    @Test func aDropOnItsOwnPaneSwapsNothing() throws {
        let window = Window()
        defer { window.window.orderOut(nil) }
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
        let strip = TabStripView.testing(model: model)
        strip.dragsWindowFromEmptySpace = false
        var intents: [TabStripIntent] = []
        model.intentHandler = { intents.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        // Gesture recognizers only see the events of a window on screen.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        strip.layoutSubtreeIfNeeded()
        let drag = PaneSwapDrag(strip: strip, pane: "p1", input: InputEventTap(), layout: { nil },
                                swap: { _, _ in })
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
        defer { window.window.orderOut(nil) }
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"))
        let shown = window.root.highlight.destinationRect
        let pane = try #require(window.root.frame(of: "p2"))
        window.release()
        #expect(shown.width > pane.width / 2)
        #expect(shown.height > pane.height / 2)
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }

    /// A frame of moves previews twice at most: the drag's start is the interval's first move and
    /// previews at once, the other moves wait and preview once at the frame, where the pointer is
    /// then.
    @Test func aFrameOfMovesPreviewsAtMostTwice() throws {
        let frames = FrameInputTestRig()
        let window = Window(frames: frames)
        defer {
            frames.close()
            window.window.orderOut(nil)
        }
        let drag = try #require(window.drags["p1"])
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"), frame: false)
        #expect(drag.previews == 1, "the start did not preview at once, or a move did before its frame: \(drag.previews)")
        #expect(frames.coalescer.hasPending, "the moves did not wait for their frame")
        frames.frame()
        #expect(drag.previews == 2, "one frame interval previewed \(drag.previews) times, not 2")
        let pane = try #require(window.root.frame(of: "p2"))
        #expect(window.root.highlight.destinationRect.width > pane.width / 2, "the frame did not preview the pane under the pointer")
        window.release()
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }

    /// A release before the frame of its moves swaps with the pane under the release, and the stale
    /// moves preview nothing after it.
    @Test func theReleaseSwapsAtItsOwnPointAndTheStaleMovesNeverRun() throws {
        let frames = FrameInputTestRig()
        let window = Window(frames: frames)
        defer {
            frames.close()
            window.window.orderOut(nil)
        }
        let drag = try #require(window.drags["p1"])
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"), frame: false)
        let previews = drag.previews
        window.release()
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
        #expect(drag.previews == previews, "the release previewed a waiting move")
        #expect(!frames.coalescer.hasPending, "the ended drag left moves waiting")
        frames.frame()
        #expect(drag.previews == previews, "a stale move previewed after the drop")
    }

    /// With the feature off each move previews at once, and the drop swaps as with it on.
    @Test func withTheFeatureOffEveryMovePreviews() throws {
        let window = Window()
        defer { window.window.orderOut(nil) }
        let drag = try #require(window.drags["p1"])
        window.hold(from: try window.emptyStripPoint("p1"), to: try window.center("p2"), frame: false)
        #expect(drag.previews >= 2, "the moves did not preview each: \(drag.previews)")
        window.release()
        #expect(window.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
    }

    /// Resampling moves only the preview's pointer: with the layout's frame-aligned input, the
    /// same moves preview the same target and the drop swaps the same panes with the resampler on and off,
    /// while the resampled preview's pointer trails the real one.
    @Test func theDropIsTheSameWithResamplingOnAndOff() throws {
        let resampledFrames = FrameInputTestRig()
        defer { resampledFrames.close() }
        let plainFrames = FrameInputTestRig()
        defer { plainFrames.close() }
        let resampled = Window(frames: resampledFrames, resampled: true)
        defer { resampled.window.orderOut(nil) }
        let plain = Window(frames: plainFrames, resampled: false)
        defer { plain.window.orderOut(nil) }
        let start = try resampled.emptyStripPoint("p1")
        let end = try resampled.center("p2")
        let plainStart = try plain.emptyStripPoint("p1")
        #expect(start == plainStart)
        for window in [resampled, plain] { window.holdInFrames(from: start, to: end) }

        let shown = try #require(resampled.drags["p1"]?.shownPointer, "the resampled drag previewed nothing")
        let plainShown = try #require(plain.drags["p1"]?.shownPointer, "the plain drag previewed nothing")
        #expect(hypot(plainShown.x - end.x, plainShown.y - end.y) < 0.5, "no resampler: the preview's pointer is the real one")
        #expect(hypot(shown.x - end.x, shown.y - end.y) > 1, "the resampled preview's pointer is the real one: \(shown)")
        #expect(resampled.root.highlight.destinationRect == plain.root.highlight.destinationRect,
                "the previewed target is hit-tested at the real pointer")
        for window in [resampled, plain] { window.release() }
        #expect(resampled.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
        #expect(plain.swaps.map { [$0.0, $0.1] } == [["p1", "p2"]])
        #expect(resampled.tap.subscriberCount(.key, stage: .intercept) == 0, "the drop left the drag's Escape intercept")
    }
}

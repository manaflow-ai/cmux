import AppKit
import CmuxNextFocusUI
import CmuxNextLayout
import CmuxNextSignposts
import CoreGraphics
import Testing

/// Every scroll event the app dispatches is timed to the frame that shows it (`key.scroll_frame`), through the
/// same input dispatch context as `key.frame` (Lawrence 2026-10-24: scrolling is measured input to frame, as
/// Chrome measures it). The timing starts with the event's own timestamp and ends with who took it: `layout`
/// when the layout scrolled (a Command pan), `content` when it went on to the pane.
@MainActor
struct ScrollFrameTimingTests {
    /// Records each timed event and the target its end reported.
    final class Recorder: ScrollFrameTiming {
        struct Row: Equatable {
            var phase: ScrollFramePhase
            var timestamp: TimeInterval
            var target: ScrollFrameTarget?
        }

        var rows: [Row] = []
        /// The rows begun and not ended, innermost last.
        private var open: [Int] = []

        func begin(phase: ScrollFramePhase, eventTimestamp: TimeInterval) {
            open.append(rows.count)
            rows.append(Row(phase: phase, timestamp: eventTimestamp, target: nil))
        }

        func end(target: ScrollFrameTarget) {
            guard let index = open.popLast() else {
                Issue.record("an end with no timing open")
                return
            }
            rows[index].target = target
        }
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let recorder = Recorder()
        let context: InputDispatchContext
        let provider = Panes()
        // Three 60% columns on a 1000 pt window: the strip overflows, so Command + scroll pans it.
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
            LayoutColumn(id: "c1", width: 0.6, root: .leaf("p1")),
            LayoutColumn(id: "c2", width: 0.6, root: .leaf("p2")),
            LayoutColumn(id: "c3", width: 0.6, root: .leaf("p3")),
        ]))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            context = InputDispatchContext(scrollFrames: recorder)
            model.followsDesignMetrics = false
            model.scrollModifierOverride = .command
            root = LayoutRootView(model: model, contentProvider: provider)
            // The App's wiring (WorkspaceContentController): the layout's take reaches the dispatch context.
            root.onScrollTaken = { [context] in context.noteLayoutTookScroll() }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        func center(_ pane: PaneID) throws -> CGPoint {
            let frame = try #require(root.frame(of: pane))
            return root.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        }

        /// One scroll event dispatched through the context, as `sendEvent` (or `debug.mouse`) dispatches it.
        @discardableResult
        func scroll(at point: CGPoint, dx: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
                    units: CGScrollEventUnit = .pixel, command: Bool = false) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            if command { cg.flags = .maskCommand }
            let event = try #require(NSEvent(cgEvent: cg))
            context.dispatching(event) { _ = root.handleScroll(event, locationInWindow: point) }
            return event
        }

        /// A sideways trackpad pan: began, three changes, ended, then a coast.
        @discardableResult
        func pan(at point: CGPoint, command: Bool) throws -> [NSEvent] {
            var events = [try scroll(at: point, dx: -20, phase: .began, command: command)]
            for _ in 0..<3 { events.append(try scroll(at: point, dx: -20, phase: .changed, command: command)) }
            events.append(try scroll(at: point, phase: .ended, command: command))
            for phase: CGMomentumScrollPhase in [.begin, .continuous, .end] {
                events.append(try scroll(at: point, dx: phase == .end ? 0 : -10, momentum: phase, command: command))
            }
            return events
        }
    }

    @Test func everyEventOfACommandPanIsTimedAsTheLayoutsFromItsOwnTimestamp() throws {
        let w = Window()
        let events = try w.pan(at: try w.center("p2"), command: true)
        #expect(w.recorder.rows.map(\.phase) == [.began, .changed, .changed, .changed, .ended, .momentum, .momentum, .momentum])
        #expect(w.recorder.rows.map(\.target) == Array(repeating: ScrollFrameTarget.layout, count: events.count))
        #expect(w.recorder.rows.map(\.timestamp) == events.map(\.timestamp), "each timing starts from its event's timestamp")
    }

    @Test func aPlainPanOverAPaneIsTimedAsTheContents() throws {
        let w = Window()
        let events = try w.pan(at: try w.center("p2"), command: false)
        #expect(w.recorder.rows.count == events.count)
        #expect(w.recorder.rows.allSatisfy { $0.target == .content }, "\(w.recorder.rows)")
    }

    @Test func aWheelIsTimedPerNotchWithWhoTookThatNotch() throws {
        let w = Window()
        let p2 = try w.center("p2")
        try w.scroll(at: p2, dx: -1, units: .line, command: true)
        try w.scroll(at: p2, dx: -1, units: .line)
        #expect(w.recorder.rows.map(\.phase) == [.wheel, .wheel])
        #expect(w.recorder.rows.map(\.target) == [.layout, .content], "the layout's take of one notch leaked into the next")
    }

    @Test func aTouchIsTimedAsATouch() throws {
        let w = Window()
        try w.scroll(at: try w.center("p2"), phase: .mayBegin, command: true)
        #expect(w.recorder.rows.map(\.phase) == [.touch])
    }

    @Test func aScrollDispatchedInsideAnotherEndsBeforeIt() throws {
        let w = Window()
        let p2 = try w.center("p2")
        let outer = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -1, wheel3: 0))
        outer.flags = .maskCommand
        let event = try #require(NSEvent(cgEvent: outer))
        try w.context.dispatching(event) {
            _ = w.root.handleScroll(event, locationInWindow: p2)
            // A synthetic notch with no Command, sent from inside the outer dispatch (`debug.mouse` from a handler).
            try w.scroll(at: p2, dx: -1, units: .line)
        }
        #expect(w.recorder.rows.map(\.target) == [.layout, .content], "each end closed its own dispatch's timing")
    }

    @Test func aDispatchThatIsNotAScrollIsNotTimed() throws {
        let w = Window()
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                                                keyCode: 0))
        w.context.dispatching(key) {}
        #expect(w.recorder.rows.isEmpty)
    }
}

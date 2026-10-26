import AppKit
import CmuxNextCompat
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The layout's motion trace points (p09-observability task 026): a pane close springs its neighbours, and the
/// window's trace ring decodes one `motion.frame` slice per tick and one `motion.run` async slice from the close
/// to the frame the springs rest in, whose end holds the frame count and the longest frame. Frames step at a
/// fixed 120 Hz dt; each test records into its own ``TraceRuntime``.
@MainActor
struct ScreenContentViewMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }

        func records(_ name: SignpostName, _ phase: TraceRuntime.Phase) -> [TraceRuntime.StubRecord] {
            records.filter { $0.name == name.rawValue && $0.phase == phase }
        }
    }

    static let dt = 1.0 / 120
    /// The frame clock's step per read: every traced frame measures exactly this long.
    static let frameNanos: UInt64 = 1_500_000

    /// A clock that advances `step` nanoseconds per read, from 0.
    nonisolated final class SteppingClock: Sendable {
        private let reads = Mutex<UInt64>(0)
        private let step: UInt64

        init(step: UInt64) { self.step = step }

        func traceClock() -> TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in
                reads.withLock { value in
                    value += step
                    return value
                }
            }, continuousNow: { ContinuousClock.now }))
        }
    }

    final class Window {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let log = RecordLog()
        let runtime: TraceRuntime

        init(motionOn: Bool = true) {
            let row: SplitNode = .split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                        b: .split("r2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(row))], activeScreenID: "s",
                                focusedPane: "p1")
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            runtime = log.runtime()
            root.motionTrace = LayoutMotionTrace(trace: runtime,
                                                 clock: SteppingClock(step: ScreenContentViewMotionTests.frameNanos).traceClock())
            if motionOn { runtime.setCategoryMask(1 << UInt64(SignpostCategory.motion.traceBit)) }
        }

        /// Cmd-W on `pane`: the structural change that starts the springs.
        func close(_ pane: PaneID) {
            _ = model.showPaneClose(pane)
            root.syncWithModel()
        }

        /// Steps until nothing moves (at most 2 s); the ticks it took.
        func settle() -> Int {
            for frame in 1...240 where !root.advanceFrame(ScreenContentViewMotionTests.dt) { return frame }
            return 240
        }
    }

    @Test func aCloseSpringDecodesOneFramePerTickAndOneRun() throws {
        let window = Window()
        window.close("p2")
        #expect(window.root.motionTrace.isRunOpen, "the close did not open a motion.run")
        let ticks = window.settle()
        #expect(ticks > 1 && ticks < 240, "the close's springs did not rest: \(ticks) ticks")
        #expect(!window.root.motionTrace.isRunOpen, "the run stayed open after the springs rested")

        let log = window.log
        let begins = log.records(.motionFrame, .begin), ends = log.records(.motionFrame, .end)
        #expect(begins.count == ticks && ends.count == ticks, "\(begins.count) B and \(ends.count) E for \(ticks) ticks")
        #expect(begins.allSatisfy { $0.arg1 == LayoutMotionTrace.micros(seconds: Self.dt) }, "a frame's dt is not the tick's")
        #expect(begins.first.map { $0.arg0 >= 2 } == true, "the first frame moved no pane: \(begins.first?.arg0 ?? 0)")

        let runBegins = log.records(.motionRun, .asyncBegin), runEnds = log.records(.motionRun, .asyncEnd)
        #expect(runBegins.count == 1 && runEnds.count == 1, "\(runBegins.count) AB and \(runEnds.count) AE")
        let begin = try #require(runBegins.first), end = try #require(runEnds.first)
        #expect(begin.arg1 == end.arg1 && begin.flags.contains(.asyncID) && end.flags.contains(.asyncID))
        #expect(end.arg0 & 0xFFFF_FFFF == UInt64(ticks), "the run counted \(end.arg0 & 0xFFFF_FFFF) frames of \(ticks)")
        #expect(end.arg0 >> 32 == Self.frameNanos / 1_000, "the longest frame is \(end.arg0 >> 32) us")
        // The run spans its frames: its begin before the first, its end after the last.
        let order = log.records.filter { $0.name == SignpostName.motionRun.rawValue || $0.name == SignpostName.motionFrame.rawValue }
        #expect(order.first?.phase == .asyncBegin && order.last?.phase == .asyncEnd)
    }

    @Test func aChangeDuringTheMotionKeepsOneRun() {
        let window = Window()
        window.close("p2")
        for _ in 1...4 { _ = window.root.advanceFrame(Self.dt) }
        window.close("p3")
        _ = window.settle()
        #expect(window.log.records(.motionRun, .asyncBegin).count == 1, "the second close opened another run")
        #expect(window.log.records(.motionRun, .asyncEnd).count == 1)
    }

    @Test func withTheMotionCategoryOffNothingIsRecorded() {
        let window = Window(motionOn: false)
        window.close("p2")
        #expect(!window.root.motionTrace.isRunOpen)
        _ = window.settle()
        #expect(window.runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(window.log.records.isEmpty)
    }

    @Test func aRunOpenWhenTheRootParksEndsThere() throws {
        let window = Window()
        window.close("p2")
        _ = window.root.advanceFrame(Self.dt)
        window.root.isHidden = true
        #expect(!window.root.motionTrace.isRunOpen, "parking left the run open")
        let end = try #require(window.log.records(.motionRun, .asyncEnd).first)
        #expect(end.arg0 & 0xFFFF_FFFF == 1)
    }
}

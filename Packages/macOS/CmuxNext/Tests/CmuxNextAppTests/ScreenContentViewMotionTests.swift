import AppKit
import CmuxNextCompat
@testable import CmuxNextLayout
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The layout's motion signposts (p09-observability task 026): a pane close springs its neighbours, and the
/// window's trace ring decodes one `motion.frame` slice per tick and one `motion.run` async slice from the close
/// to the frame the springs rest in, whose end holds the frame count and the longest frame. A split the render
/// server runs records its run too, a screen switch or a reveal counts the panes it moves, and the run reaches
/// the MetricKit mirror. Frames step at a fixed 120 Hz dt; each test records into its own ``TraceRuntime`` and
/// mirror, passed to the root through its init.
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
        let mirror = SignpostMetricKitMirror()

        static let row: ScreenLayout = .splits(.split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                      b: .split("r2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))

        /// - Parameters:
        ///   - screens: The window's screens; the first is active.
        ///   - motionOn: Whether the ring's `motion` category is on.
        ///   - renderServer: `motion.renderServer`: a split or a close springs on the render server.
        init(screens: [LayoutScreen] = [LayoutScreen(id: "s", name: "s", layout: Window.row)], motionOn: Bool = true,
             renderServer: Bool = false) {
            model = LayoutModel(screens: screens, activeScreenID: screens[0].id, focusedPane: "p1")
            model.splitSizingOverride = .even
            runtime = log.runtime()
            if motionOn { runtime.setCategoryMask(1 << UInt64(SignpostCategory.motion.traceBit)) }
            let signposter = Signposter(category: .motion, mirror: mirror, trace: runtime,
                                        clock: SteppingClock(step: ScreenContentViewMotionTests.frameNanos).traceClock())
            root = LayoutRootView(model: model, contentProvider: provider, rendersMotionOnServer: { renderServer },
                                  mainWork: MainWorkScheduler(budget: MainFrameBudget()), motionSignposter: signposter)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        var isRunOpen: Bool { root.motionTrace.openRun != nil }

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
        #expect(window.isRunOpen, "the close did not open a motion.run")
        let ticks = window.settle()
        #expect(ticks > 1 && ticks < 240, "the close's springs did not rest: \(ticks) ticks")
        #expect(!window.isRunOpen, "the run stayed open after the springs rested")

        let log = window.log
        let begins = log.records(.motionFrame, .begin), ends = log.records(.motionFrame, .end)
        #expect(begins.count == ticks && ends.count == ticks, "\(begins.count) B and \(ends.count) E for \(ticks) ticks")
        #expect(begins.allSatisfy { $0.arg1 == LayoutMotionTrace.micros(seconds: Self.dt) }, "a frame's dt is not the tick's")
        #expect(begins.first.map { $0.arg0 >= 2 } == true, "the first frame moved no pane: \(begins.first?.arg0 ?? 0)")

        let runBegins = log.records(.motionRun, .asyncBegin), runEnds = log.records(.motionRun, .asyncEnd)
        #expect(runBegins.count == 1 && runEnds.count == 1, "\(runBegins.count) AB and \(runEnds.count) AE")
        let begin = try #require(runBegins.first), end = try #require(runEnds.first)
        #expect(begin.arg1 == end.arg1 && begin.flags.contains(.asyncID) && end.flags.contains(.asyncID))
        #expect(end.arg0 == Signposter.motionRunResult(frames: UInt32(ticks), longestFrameMicros: UInt32(Self.frameNanos / 1_000)),
                "the run's end holds \(end.arg0 & 0xFFFF_FFFF) frames of \(ticks), the longest \(end.arg0 >> 32) us")
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

    @Test func withTheMotionCategoryOffTheRingRecordsNothing() {
        let window = Window(motionOn: false)
        window.close("p2")
        _ = window.settle()
        #expect(!window.isRunOpen)
        #expect(window.runtime.stubRecordCount.load(ordering: .relaxed) == 0)
        #expect(window.log.records.isEmpty)
    }

    @Test func aRunOpenWhenTheRootParksEndsThere() throws {
        let window = Window()
        window.close("p2")
        _ = window.root.advanceFrame(Self.dt)
        window.root.isHidden = true
        #expect(!window.isRunOpen, "parking left the run open")
        let end = try #require(window.log.records(.motionRun, .asyncEnd).first)
        #expect(end.arg0 & 0xFFFF_FFFF == 1)
    }

    @Test func theRunReachesTheMetricKitMirror() throws {
        let window = Window()
        window.mirror.setOn(true)
        window.close("p2")
        let run = try #require(window.root.motionTrace.openRun)
        #expect(run.isMirrored, "motion.run is on the MetricKit allowlist but its begin was not mirrored")
        _ = window.settle()
        #expect(!window.isRunOpen)
    }

    @Test func aSplitOnTheRenderServerRecordsItsRun() throws {
        let window = Window(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], renderServer: true)
        let split: SplitNode = .split("d", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
        window.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))])
        window.root.syncWithModel()
        let log = window.log
        #expect(log.records(.motionRun, .asyncBegin).count == 1, "the render server's split opened no motion.run")
        _ = window.settle()
        #expect(!window.isRunOpen, "the run stayed open after the render server's springs landed")
        #expect(log.records(.motionRun, .asyncEnd).count == 1)
        let records = log.records
        let endIndex = try #require(records.firstIndex { $0.name == SignpostName.motionRun.rawValue && $0.phase == .asyncEnd })
        // The CPU steps none of the split's springs: the run counts only the frames the CPU ran before it rested.
        let cpuFrames = records[..<endIndex].count { $0.name == SignpostName.motionFrame.rawValue && $0.phase == .begin }
        #expect(records[endIndex].arg0 & 0xFFFF_FFFF == UInt64(cpuFrames))
    }

    @Test func aScreenSwitchCountsThePanesItMoves() throws {
        let window = Window(screens: [LayoutScreen(id: "s", name: "s", layout: Window.row),
                                      LayoutScreen(id: "t", name: "t", layout: .splits(.leaf("q1")))])
        window.model.selectScreen("t")
        window.root.syncWithModel()
        #expect(window.isRunOpen, "the screen switch opened no motion.run")
        _ = window.settle()
        let first = try #require(window.log.records(.motionFrame, .begin).first)
        #expect(first.arg0 > 0, "the switch's first frame moved no pane")
    }

    @Test func aRevealScrollCountsThePanesItMoves() throws {
        let columns: ScreenLayout = .columns((1...3).map { index in
            LayoutColumn(id: ColumnID("c\(index)"), width: 0.5, root: .leaf(PaneID("p\(index)")))
        })
        let window = Window(screens: [LayoutScreen(id: "s", name: "s", layout: columns)])
        _ = window.settle()
        let before = window.log.records(.motionFrame, .begin).count
        window.model.focus("p3", notify: false)
        window.root.syncWithModel()
        #expect(window.isRunOpen, "the reveal opened no motion.run")
        _ = window.settle()
        let first = try #require(window.log.records(.motionFrame, .begin).dropFirst(before).first)
        #expect(first.arg0 > 0, "the reveal's first frame moved no pane: the strip's camera carries them all")
    }
}

import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// `motion.drag_frame` (p09-observability 039, perf-hot `drag-frame`): every ghost tick of a tab drag, or of its
/// landing flight, is one thread slice (B/E) whose begin holds the tick's dt in us; a tick for a drag that already
/// ended writes nothing. Each test records into its own ``TraceRuntime`` with only the `motion` category on, through
/// the session's injected signposter.
@MainActor @Suite(.serialized)
struct TabDragFrameTraceTests {
    /// A session on its own runtime, and the records the runtime writes.
    private static func session(_ services: AppServices) -> (TabDragSession, ScreenContentViewMotionTests.RecordLog) {
        let log = ScreenContentViewMotionTests.RecordLog()
        let runtime = log.runtime()
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.motion.traceBit))
        return (TabDragSession(services: services, motionSignposter: Signposter(category: .motion, trace: runtime)), log)
    }

    /// A tab drag's state with its ghost flying 200 points to its target, so ticks keep moving.
    private static func flyingDrag() -> TabDragSession.Drag {
        let frame = CGRect(x: 100, y: 100, width: 120, height: 28)
        let context = TabDragContext(sourcePaneID: "pane", sourcePaneTabCount: 2, sourceWorkspaceID: "workspace",
                                     sourceWorkspaceTabCount: 2, draggedTabCount: 1)
        let source = TabDragSession.Source(item: .tab("tab"), payload: nil, pane: nil, window: nil, screenFrame: frame,
                                           grabOffset: .zero, tabOffset: .zero, windowSize: CGSize(width: 800, height: 600),
                                           context: context)
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: frame.size, grabOffset: .zero, aspect: nil, scale: 1, onGlass: false)
        var motion = TabDragGhostMotion(rect: frame, cardness: 1)
        motion.setTarget(frame.offsetBy(dx: 200, dy: 0), cardness: 1, jump: true)
        return TabDragSession.Drag(source: source, lifecycle: TabDragLifecycle(restore: {}), ghost: ghost, motion: motion,
                                   point: frame.origin)
    }

    @Test func eachLandingTickIsOneThreadSliceHoldingItsDt() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (session, log) = Self.session(services)
        let landing = Self.flyingDrag()
        session.landing = landing
        defer { session.finishLanding() }
        let dt = 1.0 / 120
        #expect(session.tick(landing, elapsed: dt), "the ghost still flies")
        #expect(session.tick(landing, elapsed: dt))
        #expect(log.records.map(\.phase) == [.begin, .end, .begin, .end], "one B/E pair per tick")
        let begins = log.records(.motionDragFrame, .begin)
        #expect(begins.count == 2)
        #expect(begins.allSatisfy { $0.arg0 == 8_333 }, "begin arg0 is the tick's dt in us: \(begins.map(\.arg0))")
        #expect(log.records(.motionDragFrame, .end).allSatisfy { $0.arg0 == 0 })
    }

    @Test func aTickForADragThatEndedWritesNothing() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (session, log) = Self.session(services)
        let stale = Self.flyingDrag()
        defer { stale.ghost.close() }
        #expect(!session.tick(stale, elapsed: 1.0 / 120), "a drag that is neither the session's drag nor its landing stops")
        #expect(log.records.isEmpty)
    }

    @Test func theDtIsWholeMicrosecondsClampedAndSaturated() {
        #expect(TabDragSession.dragFrameMicros(seconds: 0) == 0)
        #expect(TabDragSession.dragFrameMicros(seconds: -1) == 0)
        #expect(TabDragSession.dragFrameMicros(seconds: .nan) == 0)
        #expect(TabDragSession.dragFrameMicros(seconds: 1.0 / 120) == 8_333)
        #expect(TabDragSession.dragFrameMicros(seconds: 0.0166) == 16_600)
        #expect(TabDragSession.dragFrameMicros(seconds: 1e9) == UInt64(UInt32.max))
        #expect(TabDragSession.dragFrameMicros(seconds: .infinity) == UInt64(UInt32.max))
    }
}

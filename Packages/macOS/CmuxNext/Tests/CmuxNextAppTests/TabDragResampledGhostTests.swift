import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextInput
import CmuxNextWakeupsTestSupport
import Testing

/// A tab or workspace drag's ghost drawn at the pointer resampled at each frame's time (feature
/// `resampledDrags`), as Chromium resamples rAF-aligned input (`MainThreadEventQueue::HandleEventResampling`,
/// `ui/base/prediction/linear_resampling.cc`): the drop target, the window order, autoscroll and the release read
/// the real pointer, so the drop is the same with the resampler on and off.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TabDragResampledGhostTests {
    typealias Fixture = TabDragSessionTests.Fixture

    /// 1/256 s between moves: exact in binary, over Chromium's kResampleMinDelta (2 ms).
    static let step = 1.0 / 256

    /// A session on `fixture`'s services whose moves go through `frames`, its ghost resampled when `resampled`.
    static func session(_ fixture: Fixture, frames: FrameInputTestRig, resampled: Bool) -> TabDragSession {
        TabDragSession(services: fixture.services, moveFrames: frames.coalescers, makeResampler: { resampled ? DragResampler() : nil })
    }

    /// Picks `fixture`'s `k1` row up into `session`.
    static func begin(_ session: TabDragSession, _ fixture: Fixture) {
        let handoff = SidebarDragHandoff(payload: .workspaces([WorkspaceID("k1")]), workspaceIDs: [WorkspaceID("k1")],
                                         rowScreenFrame: CGRect(x: 300, y: 300, width: 220, height: 28),
                                         grabOffset: CGPoint(x: 20, y: 14), screenPoint: CGPoint(x: 320, y: 314),
                                         image: nil, imageOnGlass: false)
        #expect(session.beginWorkspaces(handoff, from: fixture.controller), "the drag did not start")
    }

    /// A left mouse event with no window at the screen point `point`, at `time`.
    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    @Test func theDropIsTheSameWithResamplingOnAndOff() throws {
        let resampledFixture = try Fixture()
        defer { resampledFixture.close() }
        let plainFixture = try Fixture()
        defer { plainFixture.close() }
        let resampledFrames = FrameInputTestRig()
        defer { resampledFrames.close() }
        let plainFrames = FrameInputTestRig()
        defer { plainFrames.close() }
        let resampled = Self.session(resampledFixture, frames: resampledFrames, resampled: true)
        let plain = Self.session(plainFixture, frames: plainFrames, resampled: false)
        let runs = [(resampled, resampledFrames), (plain, plainFrames)]
        defer {
            for (session, _) in runs {
                session.finish(commit: false)
                session.finishLanding()
            }
        }
        Self.begin(resampled, resampledFixture)
        Self.begin(plain, plainFixture)

        // Rightward from the row, 30 points a move, three moves a frame from 1000 s.
        let points = (1...9).map { CGPoint(x: 320 + CGFloat($0) * 30, y: 314) }
        for (index, point) in points.enumerated() {
            for (session, frames) in runs {
                #expect(session.handle(try Self.mouse(.leftMouseDragged, at: point, time: 1000 + Double(index) * Self.step)) == .consume)
                if index % 3 == 2 { frames.frame() }
            }
            let drag = try #require(resampled.drag)
            let plainDrag = try #require(plain.drag)
            #expect(drag.point == plainDrag.point, "the hit test reads the real pointer")
            #expect(drag.workspaceOutcome == plainDrag.workspaceOutcome, "the drop target is the same at move \(index)")
            #expect(drag.workspaceHighlight == plainDrag.workspaceHighlight)
        }

        let drag = try #require(resampled.drag)
        let plainDrag = try #require(plain.drag)
        #expect(plainDrag.shownPoint == nil, "no resampler: the ghost follows the real pointer")
        let shown = try #require(drag.shownPoint, "the ghost was not resampled")
        #expect(drag.point == points[8])
        #expect(shown.x < drag.point.x, "5 ms behind a rightward drag: left of the real pointer")
        #expect(shown.y == drag.point.y)
        #expect(drag.motion.targetRect != plainDrag.motion.targetRect, "the ghost is drawn at the resampled pointer")

        // The release hit-tests at its own real point and drops there in both.
        for (session, _) in runs {
            #expect(session.handle(try Self.mouse(.leftMouseUp, at: points[8], time: 1000 + 9 * Self.step)) == .consume)
            #expect(!session.isDragging)
        }
        #expect(resampledFixture.controller.window?.frame == plainFixture.controller.window?.frame)
    }

    /// A move still waiting for its frame when the drag ends is dropped: no hit test or ghost move after the end.
    @Test func theReleaseDropsAWaitingMove() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let frames = FrameInputTestRig()
        defer { frames.close() }
        let session = Self.session(fixture, frames: frames, resampled: true)
        defer {
            session.finish(commit: false)
            session.finishLanding()
        }
        Self.begin(session, fixture)
        _ = session.handle(try Self.mouse(.leftMouseDragged, at: CGPoint(x: 350, y: 314), time: 1000))
        _ = session.handle(try Self.mouse(.leftMouseDragged, at: CGPoint(x: 380, y: 314), time: 1000 + Self.step))
        #expect(frames.coalescer.hasPending, "the second move waits for its frame")
        _ = session.handle(try Self.mouse(.leftMouseUp, at: CGPoint(x: 360, y: 314), time: 1000 + 2 * Self.step))
        #expect(!session.isDragging)
        #expect(!frames.coalescer.hasPending, "the release left a move for the frame")
    }
}

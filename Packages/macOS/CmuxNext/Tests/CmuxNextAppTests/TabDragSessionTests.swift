import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextInput
@testable import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A tab drag hears its events through one input tap intercept that lives for the drag only:
/// it takes the drag's moves, its release and Escape (no responder gets them),
/// passes other keys and the press after a lost release on, and every end (release, Escape, a press
/// after a lost release) leaves the tap with the intercepts it had before the drag.
///
/// With feature `pointerFrameDrags` its moves go to the ghost window's FrameInputCoalescer:
/// a frame interval's first move hit-tests at once, the rest once at the frame
/// at their latest point, a frame whose moves hit-tested does not hit-test again for its scroll step,
/// and the release hit-tests once at its own point. With the feature off every move hit-tests.
/// The drop over a real layout equals the per-event drag's (`TabDragFramedDropTests`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TabDragSessionTests {
    /// A window whose only workspace is `k1`, and the drag of `k1`'s sidebar row.
    final class Fixture {
        let services: AppServices
        let controller: WindowController
        /// The drag's frames: its trailing moves run when the test calls `frames.frame()`.
        let frames = PointerFrameTestRig()
        var session: TabDragSession { services.dragSession }
        var tap: InputEventTap { services.inputTap }

        /// `framed`: the feature on (the drag's moves go through `frames`); off, every move hit-tests.
        init(framed: Bool = true) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.dragSession.moveFrames = framed ? frames.coalescers : nil
            let store = services.machines.local.store
            let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            var tree = DaemonTree(registryID: "s-local", workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1"),
            ])
            tree.personal = PersonalState(workspaces: [
                PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0),
            ])
            store.apply(snapshot: tree)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"tab-drag-tap","workspace_key":"k1"}"#.utf8))
            let state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = ["k1"]
            controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        }

        /// Picks `k1`'s row up: the session takes the drag over.
        func begin() {
            let handoff = SidebarDragHandoff(payload: .workspaces([WorkspaceID("k1")]), workspaceIDs: [WorkspaceID("k1")],
                                             rowScreenFrame: CGRect(x: 300, y: 300, width: 220, height: 28),
                                             grabOffset: CGPoint(x: 20, y: 14), screenPoint: CGPoint(x: 320, y: 314),
                                             image: nil, imageOnGlass: false)
            #expect(session.beginWorkspaces(handoff, from: controller), "the drag did not start")
        }

        /// Lands the ended drag's ghost at once.
        func land() { session.finishLanding() }

        func close() {
            session.finish(commit: false)
            land()
            frames.close()
            controller.teardown()
            controller.window?.close()
        }

        /// The drag's move to `point` (screen), through the tap.
        func move(_ point: CGPoint) throws {
            #expect(tap.send(try DragEvents.mouse(.leftMouseDragged, at: point)) == .consume)
        }
    }

    @Test func theDragTakesItsMovesAndPassesOtherKeys() throws {
        let f = try Fixture()
        defer { f.close() }
        let base = f.tap.interceptCounts
        f.begin()
        #expect(f.tap.subscriberCount(.drag, stage: .intercept) == base[Int(InputEventClass.drag.rawValue)] + 1)
        #expect(f.tap.send(try DragEvents.mouse(.leftMouseDragged)) == .consume, "a responder got the drag's move")
        #expect(f.tap.send(try DragEvents.key(0, "a")) == .pass, "the drag took a key that is not Escape")
        #expect(f.tap.send(try DragEvents.mouse(.rightMouseDown)) == .pass, "the drag took a right press")
        #expect(f.session.isDragging, "another key or button ended the drag")
    }

    @Test func escapeEndsTheDragAndItsIntercept() throws {
        let f = try Fixture()
        defer { f.close() }
        let base = f.tap.interceptCounts
        f.begin()
        #expect(f.tap.send(try DragEvents.key()) == .consume, "Escape went on to a responder")
        #expect(!f.session.isDragging)
        f.land()
        #expect(f.tap.interceptCounts == base, "Escape left an intercept")
    }

    /// Released outside every window, the window's only workspace moves the window there.
    @Test func theReleaseEndsTheDragAndItsIntercept() throws {
        let f = try Fixture()
        defer { f.close() }
        let base = f.tap.interceptCounts
        f.begin()
        #expect(f.tap.send(try DragEvents.mouse(.leftMouseUp)) == .consume, "the release went on to a responder")
        #expect(!f.session.isDragging)
        f.land()
        #expect(f.tap.interceptCounts == base, "the release left an intercept")
    }

    /// A press while the drag runs means a tracking loop took its release: the drag ends with
    /// nothing dropped and the press goes on to what it hit.
    @Test func aPressAfterALostReleaseEndsTheDragAndGoesOn() throws {
        let f = try Fixture()
        defer { f.close() }
        let base = f.tap.interceptCounts
        f.begin()
        #expect(f.tap.send(try DragEvents.mouse(.leftMouseDown)) == .pass, "the drag kept the press")
        #expect(!f.session.isDragging)
        f.land()
        #expect(f.tap.interceptCounts == base, "the press left an intercept")
        #expect(f.tap.send(try DragEvents.key()) == .pass, "an ended drag still took Escape")
    }

    /// Eight moves in a frame interval: the first hit-tests at once, the other seven once at the
    /// frame at their latest point; the release velocity still hears every move.
    @Test func aFrameOfMovesHitTestsTwiceAtMostAtItsLatestPoint() throws {
        let f = try Fixture()
        defer { f.close() }
        f.begin()
        let drag = try #require(f.session.drag)
        var expected = drag.hitTests
        for frame in 0..<3 {
            var last = CGPoint.zero
            for step in 1...8 {
                last = CGPoint(x: -20_000 + CGFloat(frame * 100 + step * 10), y: -20_000)
                try f.move(last)
                if step == 1 { expected += 1 }
                #expect(drag.hitTests == expected, "frame \(frame) move \(step): \(drag.hitTests) hit tests, not \(expected)")
            }
            f.frames.frame()
            expected += 1
            #expect(drag.hitTests == expected, "frame \(frame) made \(drag.hitTests - expected + 2) hit tests, not 2")
            #expect(drag.point == last, "the frame hit-tested \(drag.point), not its latest move \(last)")
        }
        #expect(drag.lastPointerSample?.point == CGPoint(x: -20_000 + 280, y: -20_000), "a coalesced move missed the velocity")
    }

    /// With the feature off each move hit-tests at once, as before p04-input-032.
    @Test func withTheFeatureOffEveryMoveHitTests() throws {
        let f = try Fixture(framed: false)
        defer { f.close() }
        f.begin()
        let drag = try #require(f.session.drag)
        #expect(drag.moves == nil, "the drag coalesced with the feature off")
        let before = drag.hitTests
        for step in 1...8 { try f.move(CGPoint(x: -20_000 + CGFloat(step), y: -20_000)) }
        #expect(drag.hitTests == before + 8)
        #expect(drag.point == CGPoint(x: -19_992, y: -20_000))
    }

    /// A release before the frame of its moves hit-tests once, at the release point; the waiting
    /// moves are dropped, not hit-tested first, and never run after it.
    @Test func theReleaseHitTestsOnceAtItsOwnPointAndTheWaitingMovesNeverRun() throws {
        let f = try Fixture()
        defer { f.close() }
        f.begin()
        let drag = try #require(f.session.drag)
        for step in 1...8 { try f.move(CGPoint(x: -20_000 + CGFloat(step), y: -20_000)) }
        #expect(f.frames.coalescer.hasPending, "the moves after the first did not wait for their frame")
        let release = CGPoint(x: -19_000, y: -19_500)
        let before = drag.hitTests
        #expect(f.tap.send(try DragEvents.mouse(.leftMouseUp, at: release)) == .consume)
        #expect(!f.session.isDragging)
        #expect(drag.hitTests == before + 1, "the release made \(drag.hitTests - before) hit tests, not 1")
        #expect(drag.point == release, "the drop used \(drag.point), not the release point")
        #expect(!f.frames.coalescer.hasPending, "the ended drag left moves waiting")
        f.frames.frame()
        #expect(drag.hitTests == before + 1, "a waiting move hit-tested after the drop")
    }

    /// A frame that delivers moves and steps the edge auto-scroll makes two hit tests, not three:
    /// the frame's moves hit-tested, so its scroll step does not (the next frame does). A frame that
    /// only scrolls hit-tests once. The auto-scroll target is the one a hit test over a columns
    /// screen's trailing band resolves (`DragAutoscrollTests`); the drag's points are under no
    /// window, so each hit test clears it and the test sets it again before the ghost's frame.
    @Test func aFrameOfMovesAndAScrollStepHitTestsTwiceAtMost() throws {
        let f = try Fixture()
        defer { f.close() }
        let columns = DragAutoscrollTests.Screen()
        f.begin()
        let drag = try #require(f.session.drag)
        let target = try #require(columns.root.tabDragAutoscroll(locationInWindow: try columns.edgePoint(trailing: true)))
        let before = drag.hitTests
        for step in 1...8 { try f.move(CGPoint(x: -20_000 + CGFloat(step), y: -20_000)) }
        f.frames.frame()
        #expect(drag.hitTests == before + 2, "the frame's moves made \(drag.hitTests - before) hit tests, not 2")
        // The ghost's frame of the same display frame, with the pointer in the strip's band.
        (drag.autoscroll, drag.autoscrollLayout) = (target, columns.root)
        let scrolledFrom = try columns.view.scroll.target
        #expect(f.session.tick(drag, elapsed: 1.0 / 120), "a scrolling ghost frame went idle")
        #expect(try columns.view.scroll.target > scrolledFrom, "the ghost frame did not scroll the strip")
        #expect(drag.hitTests == before + 2, "the scroll step of a frame whose moves hit-tested hit-tested again")
        // The next frame has no move: content moved under the resting pointer, one hit test.
        (drag.autoscroll, drag.autoscrollLayout) = (target, columns.root)
        _ = f.session.tick(drag, elapsed: 1.0 / 120)
        #expect(drag.hitTests == before + 3, "a frame that only scrolled made \(drag.hitTests - before - 2) hit tests, not 1")
    }
}

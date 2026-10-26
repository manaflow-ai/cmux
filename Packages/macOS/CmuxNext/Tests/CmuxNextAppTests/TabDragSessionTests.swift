import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextInput
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A tab drag hears its events through one input tap intercept that lives for the drag only
/// (p04-input-015): it takes the drag's moves, its release and Escape (no responder gets them),
/// passes other keys and the press after a lost release on, and every end (release, Escape, a press
/// after a lost release) leaves the tap with the intercepts it had before the drag.
///
/// Its moves run once per frame (p04-input-032): a frame's moves make one hit test at the frame's
/// latest point, the release hit-tests at its own point, and a drop lands where the per-event drag
/// of the same moves landed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TabDragSessionTests {
    /// A window whose only workspace is `k1`, and the drag of `k1`'s sidebar row.
    final class Fixture {
        let services: AppServices
        let controller: WindowController
        /// The drag's frames: its moves run when the test ticks.
        let frames = DragFrames()
        var session: TabDragSession { services.dragSession }
        var tap: InputEventTap { services.inputTap }

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]), frameInput: frames.coalescers)
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
            controller.teardown()
            controller.window?.close()
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

    /// Eight moves in one frame make no hit test until the frame, then one at the frame's latest
    /// point; the release velocity still hears every move.
    @Test func aFrameOfMovesHitTestsOnceAtItsLatestPoint() throws {
        let f = try Fixture()
        defer { f.close() }
        f.begin()
        let drag = try #require(f.session.drag)
        let started = drag.hitTests
        for frame in 0..<3 {
            var last = CGPoint.zero
            for step in 1...8 {
                last = CGPoint(x: -20_000 + CGFloat(frame * 100 + step * 10), y: -20_000)
                #expect(f.tap.send(try DragEvents.mouse(.leftMouseDragged, at: last)) == .consume)
            }
            #expect(drag.hitTests == started + frame, "a move hit-tested before its frame")
            f.frames.tick()
            #expect(drag.hitTests == started + frame + 1, "frame \(frame) made \(drag.hitTests - started - frame) hit tests")
            #expect(drag.point == last, "the frame hit-tested \(drag.point), not its latest move \(last)")
        }
        #expect(drag.lastPointerSample?.point == CGPoint(x: -20_000 + 280, y: -20_000), "a coalesced move missed the velocity")
    }

    /// A release before the frame of its moves drops at the release point; the stale moves never
    /// hit-test after it.
    @Test func theReleaseDropsAtItsOwnPointAndTheStaleMovesNeverRun() throws {
        let f = try Fixture()
        defer { f.close() }
        f.begin()
        let drag = try #require(f.session.drag)
        for step in 1...8 {
            f.tap.send(try DragEvents.mouse(.leftMouseDragged, at: CGPoint(x: -20_000 + CGFloat(step), y: -20_000)))
        }
        let release = CGPoint(x: -19_000, y: -19_500)
        let before = drag.hitTests
        #expect(f.tap.send(try DragEvents.mouse(.leftMouseUp, at: release)) == .consume)
        #expect(!f.session.isDragging)
        #expect(drag.hitTests == before + 1, "the release did not hit-test once")
        #expect(drag.point == release, "the drop used \(drag.point), not the release point")
        f.frames.tick()
        #expect(drag.hitTests == before + 1, "a stale move hit-tested after the drop")
    }

    /// The app flushes a frame's moves before a release (`FrameInputCoalescers.willDispatch`): the
    /// stale move and the release make two hit tests in that frame, and the drop lands where the
    /// per-event drag of the same moves landed.
    @Test func theDropEqualsTheDropOfThePerEventDrag() throws {
        let moves = (1...12).map { CGPoint(x: 1_400 + CGFloat($0) * 7, y: 120 + CGFloat($0) * 3) }
        let release = CGPoint(x: 1_520, y: 170)

        // The per-event drag (a hit test per move, as before p04-input-032); its window closes before
        // the framed drag runs, so it is under none of that drag's points.
        let perEvent = try Fixture()
        perEvent.begin()
        for point in moves { perEvent.session.update(point) }
        perEvent.tap.send(try DragEvents.mouse(.leftMouseUp, at: release))
        let perEventFrame = perEvent.controller.window?.frame
        perEvent.close()

        let framed = try Fixture()
        defer { framed.close() }
        framed.begin()
        let drag = try #require(framed.session.drag)
        for (index, point) in moves.enumerated() {
            framed.tap.send(try DragEvents.mouse(.leftMouseDragged, at: point))
            if index == 5 { framed.frames.tick() }
        }
        let before = drag.hitTests
        framed.frames.coalescers.willDispatch(.leftMouseUp)
        framed.tap.send(try DragEvents.mouse(.leftMouseUp, at: release))
        #expect(drag.hitTests - before <= 2, "the release frame made \(drag.hitTests - before) hit tests")
        #expect(drag.point == release)
        #expect(framed.controller.window?.frame == perEventFrame, "the framed drag dropped elsewhere")
    }
}

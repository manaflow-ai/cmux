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
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TabDragSessionTests {
    /// A window whose only workspace is `k1`, and the drag of `k1`'s sidebar row.
    final class Fixture {
        let services: AppServices
        let controller: WindowController
        var session: TabDragSession { services.dragSession }
        var tap: InputEventTap { services.inputTap }

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
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
}

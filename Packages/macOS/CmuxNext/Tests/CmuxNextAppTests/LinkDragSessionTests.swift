import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Foundation
import Testing

/// A link dragged out of a chat hears its events through one input tap intercept that lives for the
/// drag only: it takes the drag's moves, its release and Escape, passes other keys
/// and the press after a lost release on, and every end leaves the tap's intercepts as they were.
/// With feature `pointerFrameDrags` its moves hit-test on a frame interval's first move and once at
/// the frame, and the release hit-tests once at its own point.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LinkDragSessionTests {
    let services = AppServices(environment: AppEnvironment.current([:]))
    let url = URL(fileURLWithPath: "/tmp/cmux-link-drag-session.md")

    var session: LinkDragSession { services.linkDrags }
    var tap: InputEventTap { services.inputTap }

    @Test func theDragTakesItsMovesAndPassesOtherKeys() throws {
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        defer { _ = try? tap.send(DragEvents.key()) }
        #expect(tap.send(try DragEvents.mouse(.leftMouseDragged)) == .consume, "a responder got the drag's move")
        #expect(tap.send(try DragEvents.key(0, "a")) == .pass, "the drag took a key that is not Escape")
        #expect(session.isDragging, "another key ended the drag")
    }

    @Test(arguments: [DragEndPath.escape, .release, .pressAfterLostRelease])
    func everyEndDropsTheIntercept(_ path: DragEndPath) throws {
        let base = tap.interceptCounts
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        #expect(tap.interceptCounts != base, "the drag installed no intercept")
        #expect(tap.send(try path.event()) == path.result, "\(path) was not \(path.result)")
        #expect(!session.isDragging, "\(path) did not end the drag")
        #expect(tap.interceptCounts == base, "\(path) left an intercept")
    }

    /// Eight moves in a frame interval make two hit tests (the first at once, the rest at the frame);
    /// the release drops the waiting moves and hit-tests once at its own point.
    @Test func aFrameOfMovesHitTestsTwiceAndTheReleaseOnce() throws {
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        services.dragFrameInput = frames.coalescers
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        let started = session.hitTests
        for step in 1...8 {
            tap.send(try DragEvents.mouse(.leftMouseDragged, at: CGPoint(x: DragEvents.offScreen.x + CGFloat(step), y: DragEvents.offScreen.y)))
        }
        #expect(session.hitTests == started + 1, "the moves before their frame made \(session.hitTests - started) hit tests, not 1")
        frames.frame()
        #expect(session.hitTests == started + 2, "the frame interval made \(session.hitTests - started) hit tests, not 2")
        for step in 1...4 {
            tap.send(try DragEvents.mouse(.leftMouseDragged, at: CGPoint(x: DragEvents.offScreen.x - CGFloat(step), y: DragEvents.offScreen.y)))
        }
        #expect(frames.coalescer.hasPending)
        #expect(tap.send(try DragEvents.mouse(.leftMouseUp)) == .consume)
        #expect(!session.isDragging)
        #expect(session.hitTests == started + 4, "the release made \(session.hitTests - started - 3) hit tests, not 1")
        frames.frame()
        #expect(session.hitTests == started + 4, "a waiting move hit-tested after the drop")
    }

    /// With the feature off each move hit-tests at once.
    @Test func withTheFeatureOffEveryMoveHitTests() throws {
        services.dragFrameInput = nil
        #expect(session.begin(url, screenPoint: DragEvents.offScreen))
        defer { _ = try? tap.send(DragEvents.key()) }
        let started = session.hitTests
        for _ in 1...8 { tap.send(try DragEvents.mouse(.leftMouseDragged)) }
        #expect(session.hitTests == started + 8)
    }
}

/// The ways a drag ends from its input, the event that ends it, and what the tap does with it.
nonisolated enum DragEndPath: CustomStringConvertible, Sendable {
    case escape, release, pressAfterLostRelease

    @MainActor func event() throws -> NSEvent {
        switch self {
        case .escape: try DragEvents.key()
        case .release: try DragEvents.mouse(.leftMouseUp)
        case .pressAfterLostRelease: try DragEvents.mouse(.leftMouseDown)
        }
    }

    /// Escape and the release stop at the drag; the press goes on to what it hit.
    var result: InputEventTap.InterceptResult { self == .pressAfterLostRelease ? .pass : .consume }

    var description: String {
        switch self {
        case .escape: "Escape"
        case .release: "the release"
        case .pressAfterLostRelease: "a press after a lost release"
        }
    }
}

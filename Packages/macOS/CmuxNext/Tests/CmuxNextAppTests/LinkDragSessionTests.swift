import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Foundation
import Testing

/// A link dragged out of a chat hears its events through one input tap intercept that lives for the
/// drag only (p04-input-015): it takes the drag's moves, its release and Escape, passes other keys
/// and the press after a lost release on, and every end leaves the tap's intercepts as they were.
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

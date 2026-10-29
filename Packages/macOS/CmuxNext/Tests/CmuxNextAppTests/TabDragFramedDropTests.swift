import AppKit
@testable import CmuxNextApp
import CmuxNextInput
import Foundation
import Testing

/// A tab drag over a real layout drops where the per-event drag of the same moves drops:
/// with feature `pointerFrameDrags` its moves hit-test on a frame interval's first move and at the frame,
/// and the release hit-tests at its own point, so a pane's center and a pane's edge split resolve to the
/// same winner and outcome as when every move hit-tests. `k0`'s first tab is dragged from its strip,
/// through the tap, onto `k0`'s pane. These run in the serialized `SidebarMultiViewWindowTests`.
extension SidebarMultiViewWindowTests {
    /// Where the drag of `k0`'s tab is released.
    enum FramedDropSpot: CustomStringConvertible, CaseIterable, Sendable {
        case paneCenter, leftEdgeSplit

        @MainActor func point(_ f: Fixture) throws -> CGPoint {
            switch self {
            case .paneCenter: return try f.paneCenter(of: "k0", index: 0).1
            case .leftEdgeSplit: return try f.edgePoint(.left)
            }
        }

        var description: String { self == .paneCenter ? "a pane's center" : "a pane's left edge split" }
    }

    /// What a drop resolved: its winner's proposal and its outcome.
    struct FramedDrop: Equatable {
        let winner: String?
        let outcome: String
    }

    @Test(arguments: FramedDropSpot.allCases)
    func aFramedTabDropEqualsThePerEventDrop(_ spot: FramedDropSpot) async throws {
        let perEvent = try await dropTab(at: spot, framed: false)
        let framed = try await dropTab(at: spot, framed: true)
        #expect(perEvent.winner != nil, "nothing answered at \(spot)")
        #expect(framed == perEvent, "the framed drop at \(spot) resolved \(framed), the per-event one \(perEvent)")
    }

    /// Drags `k0`'s first tab from its strip to `spot` in twelve moves through the tap and releases it there;
    /// `framed`: through a frame input coalescer whose frame comes after every third move.
    private func dropTab(at spot: FramedDropSpot, framed: Bool) async throws -> FramedDrop {
        let f = try await Fixture()
        let frames = PointerFrameTestRig()
        defer {
            frames.close()
            f.close()
        }
        f.services.dragSession.moveFrames = framed ? frames.coalescers : nil
        try f.beginTabDrag()
        let drag = try #require(f.services.dragSession.drag)
        #expect((drag.moves != nil) == framed, "the drag's moves are \(drag.moves == nil ? "per event" : "framed")")
        let start = drag.point
        let end = try spot.point(f)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            #expect(f.services.inputTap.send(try DragEvents.mouse(.leftMouseDragged, at: point)) == .consume)
            if framed, step % 3 == 0 { frames.frame() }
        }
        #expect(f.services.inputTap.send(try DragEvents.mouse(.leftMouseUp, at: end)) == .consume)
        #expect(!f.services.dragSession.isDragging, "the release did not end the drag")
        f.frame()
        // A strip's ID is new in each window: name the strip by its pane, which the daemon's tree names.
        let strips = (f.controller.content?.panes.values).map { Array($0) } ?? []
        func named(_ text: String) -> String {
            strips.reduce(text) { $0.replacingOccurrences(of: $1.stripModel.stripID.uuidString, with: "strip of \($1.layoutPaneID)") }
        }
        return FramedDrop(winner: drag.winner.map { named(String(describing: $0.proposal.kind)) }, outcome: named(String(describing: drag.outcome)))
    }
}

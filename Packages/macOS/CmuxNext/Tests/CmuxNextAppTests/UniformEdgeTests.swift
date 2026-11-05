@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// `UniformEdge`: the width every column takes in a Command column-edge drag so the dragged edge rests where the
/// pointer puts it, with the camera the anchored sync gives it (columns of 8 pt gaps on a 1000 pt viewport).
struct UniformEdgeTests {
    /// Columns of `widths` points from x = 8 with 8 pt gaps, the dragged one at `index`, the camera at `camera`.
    static func solver(_ widths: [CGFloat], index: Int, camera: CGFloat) -> UniformEdge {
        let left = 8 + widths.prefix(index).reduce(0) { $0 + $1 + 8 }
        let content = 8 + widths.reduce(0) { $0 + $1 + 8 }
        return UniformEdge(widths: widths, index: index, left: left, content: content, viewport: 1000, camera: camera)
    }

    @Test func aStripThatFitsSharesThePointersTravelAmongTheColumnsUpToTheEdge() throws {
        // Three 300 pt columns fit; c1's edge 30 pt right: c0 and c1 grow 15 pt each, and the camera stays at 0.
        let solver = Self.solver([300, 300, 300], index: 1, camera: 0)
        let width = try #require(solver.width(restingEdgeAt: solver.edge(300) + 30))
        #expect(abs(width - 315) < 0.01, "every column is \(width) pt")
        #expect(solver.presented(width) == 0)
    }

    @Test func aCameraWithRoomTakesTheShiftAndTheWidthTakesThePointersTravel() throws {
        let solver = Self.solver([600, 600, 600], index: 1, camera: 100)
        let width = try #require(solver.width(restingEdgeAt: solver.edge(600) + 30))
        #expect(abs(width - 630) < 0.01, "every column is \(width) pt")
        #expect(abs(solver.presented(width) - 130) < 0.01, "the camera shows \(solver.presented(width)) pt")
    }

    @Test func aCameraAtTheStripsStartSharesWhatItCannotTake() throws {
        // The camera 10 pt from the start; c1's edge 30 pt left: the camera takes 10 pt of c0's shrink, the edge stays
        // under the pointer.
        let solver = Self.solver([600, 600, 600], index: 1, camera: 10)
        let place = solver.edge(600) - 30
        let width = try #require(solver.width(restingEdgeAt: place))
        #expect(abs(solver.edge(width) - place) < 0.01)
        #expect(solver.presented(width) == 0)
    }

    @Test func aCameraMidSpringShowsTheEdgeUnderThePointerInThisFrame() throws {
        // The camera shows 0 pt on its way to 100 pt; c0's edge (608 pt on screen) 30 pt right: every column 630 pt, the
        // edge at 638 pt with the camera at 0 (no anchor shift for the first column), not 730 pt measured at the target.
        let atRest = Self.solver([600, 600, 600], index: 0, camera: 100)
        let solver = UniformEdge(widths: atRest.widths, index: 0, left: atRest.left, content: atRest.content, viewport: 1000,
                                 camera: 100, shown: 0)
        let width = try #require(solver.width(restingEdgeAt: 638))
        #expect(abs(width - 630) < 0.01, "every column is \(width) pt")
    }

    @Test func atTheStripsEndTheLastColumnsEdgeCannotFollowAShrink() {
        // The camera at the end (832 pt): the content pins the last column's edge to the viewport's. The only width that
        // would rest it 30 pt left makes the whole strip fit (about 313 pt): a jump, not a drag.
        let solver = Self.solver([600, 600, 600], index: 2, camera: 832)
        #expect(solver.width(restingEdgeAt: solver.edge(600) - 30) == nil)
    }
}

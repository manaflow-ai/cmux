import CmuxAgentCursor
@testable import CmuxNextAgentCursor
import Foundation
import QuartzCore
import Testing

/// Cursor shape gallery S1 "Soft classic" (user, 2026-10-20: "The shape is not
/// perfect yet. Think from first principles about how to make the cursor shape
/// even more friendly and perfect"): the system pointer's posture (a vertical
/// left edge, a body that leans right, taller than wide) with every corner
/// rounded and a shallow notch for a back, and the name tag clear of it.
@MainActor
struct AgentCursorArrowShapeTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    private let path = AgentCursorLayer.arrowPath

    /// The points of the body on a 0.25 pt grid.
    private var body: [CGPoint] {
        let box = path.boundingBoxOfPath
        return stride(from: box.minX, through: box.maxX, by: 0.25).flatMap { x in
            stride(from: box.minY, through: box.maxY, by: 0.25).map { CGPoint(x: x, y: $0) }
        }.filter { path.contains($0) }
    }

    @Test func itStandsLikeTheSystemPointer() {
        let box = path.boundingBoxOfPath
        let ratio = box.height / box.width
        #expect(ratio > 1.25 && ratio < 1.6, "taller than wide, not a symmetric dart (h/w \(ratio))")
        for y in stride(from: CGFloat(4), through: 14, by: 2) {
            #expect(path.contains(CGPoint(x: 0.5, y: y)), "the left edge runs straight down from the tip (y \(y))")
        }
    }

    @Test func itHasANotchedBack() {
        let box = path.boundingBoxOfPath
        // Just behind the notch on the body's axis, inside the bounding box but outside the body.
        let behind = CGPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.73)
        #expect(!path.contains(behind), "a back, not a filled triangle")
    }

    @Test func itWeighsAboutAsMuchAsTheSystemPointer() {
        let area = CGFloat(body.count) * 0.0625
        #expect(area > 70 && area < 100, "body \(area) pt²")
        #expect(path.boundingBoxOfPath.height > 14.5 && path.boundingBoxOfPath.height < 17, "a peer of the person's own pointer")
    }

    @Test func itRestsAlongItsOwnAxis() throws {
        let points = body
        let mid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                          y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        let axis = atan2(Double(mid.y), Double(mid.x))
        #expect(abs(axis - AgentCursorOverlayModel.restingHeading) < 5 * .pi / 180,
                "a glide turns the arrow by its heading less its resting heading, so they must agree")
    }

    @Test func theNameTagClearsTheArrow() throws {
        let stack = AgentCursorStack(hostLayer: CALayer(), resolver: Visible())
        stack.host.apply(.place(session: "cmux-browser-cli:Claude", point: CGPoint(x: 100, y: 100)))
        let cursor = try #require(stack.host.cursorLayer(for: "cmux-browser-cli:Claude"))
        let zone = cursor.nameTag.frame.insetBy(dx: -1.5, dy: -1.5)
        #expect(!cursor.nameTag.isHidden)
        let hits = stride(from: zone.minX, through: zone.maxX, by: 0.5).flatMap { x in
            stride(from: zone.minY, through: zone.maxY, by: 0.5).map { CGPoint(x: x, y: $0) }
        }.filter { path.contains($0) }
        #expect(hits.isEmpty, "the tag and its 1.5 pt margin stay off the arrow")
        #expect(zone.minY < path.boundingBoxOfPath.maxY, "the tag still hangs beside the arrow, not far below it")
    }
}

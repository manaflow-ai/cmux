import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The corners of a floating pane's card: each one follows the window's corner by the concentric rule (the
/// window's radius less the corner's distance from the window's edges), and is never below the floor.
@MainActor struct FloatingPaneCardCornerTests {
    let size = CGSize(width: 300, height: 200)

    func corners(left: CGFloat, top: CGFloat, right: CGFloat = 500, bottom: CGFloat = 300, window: CGFloat = 16,
                 floor: CGFloat = 6, size: CGSize? = nil) -> FloatingPaneCorners {
        FloatingPaneCorners(size: size ?? self.size, left: left, top: top, right: right, bottom: bottom, windowRadius: window, floor: floor)
    }

    func near(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 1e-6 && abs(first.minY - second.minY) < 1e-6
            && abs(first.maxX - second.maxX) < 1e-6 && abs(first.maxY - second.maxY) < 1e-6
    }

    @Test func aCornerNearTheWindowsCornerIsConcentricWithIt() {
        let near = corners(left: 4, top: 4)
        #expect(near.topLeft == 12, "the window's 16 less the 4 pt gap")
        #expect(near.topRight == 6 && near.bottomLeft == 6 && near.bottomRight == 6, "the 3 other corners are far from the edges")
        #expect(corners(left: 2, top: 6).topLeft == 10, "with 2 distances the larger one gives the radius")
        #expect(corners(left: 0, top: 0).topLeft == 16, "a corner on the window's corner has the window's radius")
        #expect(corners(left: -8, top: -8).topLeft == 16, "a distance below 0 is 0")
        #expect(corners(left: 500, top: 300, right: 4, bottom: 4).bottomRight == 12)
    }

    @Test func aCornerIsNeverBelowTheFloor() {
        #expect(corners(left: 240, top: 160) == FloatingPaneCorners(uniform: 6), "away from each edge: the floor at each corner")
        #expect(corners(left: 4, top: 12).topLeft == 6, "16 less 12 is below the floor")
        #expect(corners(left: 4, top: 4, window: 0) == FloatingPaneCorners(uniform: 6), "a window with square corners: the floor")
        #expect(corners(left: 4, top: 4, floor: 0).bottomRight == 0)
    }

    @Test func aRadiusIsAtMostHalfTheShorterSide() {
        let small = corners(left: 0, top: 0, size: CGSize(width: 40, height: 10))
        #expect(small.topLeft == 5 && small.bottomRight == 5)
    }

    @Test func theContentHasTheLargestCornersRadiusLessItsInset() {
        #expect(corners(left: 4, top: 4).contentRadius(inset: 5) == 7)
        #expect(FloatingPaneCorners(uniform: 3).contentRadius(inset: 5) == 0, "never below 0")
    }

    @Test func theOutlineIsInsideItsRectangleAndCutsEachCorner() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let path = corners(left: 4, top: 4).path(in: rect)
        #expect(near(path.boundingBoxOfPath, rect))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        // The top left corner has 12 pt: a point 1 pt in from the corner is outside the curve; with 6 pt at the
        // bottom right, a point 3 pt in is inside and a point 1 pt in is outside.
        #expect(!path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)))
        #expect(!path.contains(CGPoint(x: rect.minX + 3, y: rect.minY + 3)))
        #expect(path.contains(CGPoint(x: rect.maxX - 3, y: rect.maxY - 3)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)))
        #expect(near(corners(left: 4, top: 4).path(in: rect, inset: 5).boundingBoxOfPath, rect.insetBy(dx: 5, dy: 5)))
        #expect(corners(left: 4, top: 4).path(in: CGRect(x: 0, y: 0, width: 8, height: 8), inset: 5).isEmpty)
    }

    /// A knob changes no default: the look with no knob set is the look of the code, and it is not see-through.
    @Test func theLooksDefaultsAreTheCodesDefaults() {
        let look = FloatingPaneLook()
        #expect(look.cornerMode == .concentric)
        #expect(look.cornerFloor == CGFloat(FloatingPaneTunables.defaultCornerFloor))
        #expect(look.backgroundOpacity == 1 && !look.isSeeThrough)
        #expect(look.material == FloatingPaneMaterial.none && look.material.system == nil)
        var seeThrough = look
        seeThrough.backgroundOpacity = 0.8
        #expect(seeThrough.isSeeThrough)
        #expect(FloatingPaneTunables.all.first?.key == FloatingPaneTunables.backgroundOpacity.descriptor.key, "the background opacity is the first knob")
    }
}

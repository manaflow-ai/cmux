import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The status glyphs' 1x pixel art fits a 10-pixel grid only. A 10 pt glyph on a 3x screen (30 px)
/// or a 5x render (50 px) drew that art blown up, in coarse blocks; it now draws the master's
/// curves, as at 2x (review on #20410).
struct StaticStatusGlyphScaleTests {
    private static func curves(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .addCurveToPoint, .addQuadCurveToPoint: count += 1
            default: break
            }
        }
        return count
    }

    @Test func onlyTenDevicePixelsTakeThePixelArt() {
        let rings = [10, 20, 30, 40, 50].map { side in
            (side, Self.curves(StaticStatusGlyph.idle.path(in: CGRect(x: 0, y: 0, width: side, height: side))))
        }
        for (side, curves) in rings {
            if side == 10 {
                #expect(curves == 0, "10 px: the pixel art, all squares")
            } else {
                #expect(curves > 0, "\(side) px: the master's ring, not the 10 px art blown up")
            }
        }
    }
}

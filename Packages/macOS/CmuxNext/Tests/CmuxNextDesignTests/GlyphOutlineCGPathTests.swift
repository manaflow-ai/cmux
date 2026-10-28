import CmuxNextCompat
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// The `CGPath`s the layers and image exports draw are the ones DesignTokens built before its shapes
/// became ``OutlinePath`` values: each expected path is the old construction.
@Suite struct GlyphOutlineCGPathTests {
    @Test func theLaunchMarkDrawsTheSamePath() {
        let rect = CGRect(x: 1.5, y: 1.5, width: 37, height: 29)
        let box = CGRect(x: 91, y: 65, width: 88, height: 126)
        let corners = [CGPoint(x: 91, y: 65), CGPoint(x: 179, y: 128), CGPoint(x: 91, y: 191),
                       CGPoint(x: 91, y: 151), CGPoint(x: 139, y: 128), CGPoint(x: 91, y: 105)]
        let scale = min(rect.width / box.width, rect.height / box.height)
        let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
        let expected = CGMutablePath()
        expected.addLines(between: corners.map {
            CGPoint(x: origin.x + ($0.x - box.minX) * scale, y: origin.y + (box.maxY - $0.y) * scale)
        })
        expected.closeSubpath()
        #expect(OutlinePath.launchMark(in: rect).cgPath == expected)
    }

    @Test func theStatusGlyphsDrawTheSamePaths() {
        let rect = CGRect(x: 0, y: 0, width: 14, height: 14)
        let start: CGFloat = .pi / 2
        let end: CGFloat = start - 2 * .pi
        let ring = CGMutablePath()
        ring.addArc(center: CGPoint(x: 7, y: 7), radius: 6, startAngle: start, endAngle: end, clockwise: true)
        #expect(StatusGlyphGeometry.ringPath(in: rect, thickness: 2).cgPath == ring)

        let check = CGMutablePath()
        check.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5))
        check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.12))
        check.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        #expect(StatusGlyphGeometry.checkPath(in: rect).cgPath == check)

        let frame = CGRect(x: 3, y: 2, width: 4, height: 9)
        let own = CGRect(origin: .zero, size: frame.size)
        let dot = CGPath(ellipseIn: own, transform: nil)
        let bar = CGPath(roundedRect: own, cornerWidth: 2, cornerHeight: 2, transform: nil)
        #expect(StatusGlyphGeometry.repeatedElementPath(frame, bars: false).cgPath == dot)
        #expect(StatusGlyphGeometry.repeatedElementPath(frame, bars: true).cgPath == bar)
    }
}

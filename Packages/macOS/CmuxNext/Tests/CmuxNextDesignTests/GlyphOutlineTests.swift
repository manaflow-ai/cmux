import CmuxNextCompat
import CmuxNextDesignTokens
import Foundation
import Testing

/// The launch mark and the status glyphs are Foundation geometry in DesignTokens (``OutlinePath``), so
/// their shapes build and are checked without CoreGraphics.
@Suite struct GlyphOutlineTests {
    @Test func theLaunchMarkIsTheChevronFittedAndCenteredYUp() {
        // The chevron's box is 88 by 126: a 44 by 126 rect fits it at scale 0.5, centered at (22, 63) in y-up space.
        let path = OutlinePath.launchMark(in: CGRect(x: 0, y: 0, width: 44, height: 126))
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 94.5), CGPoint(x: 44, y: 63), CGPoint(x: 0, y: 31.5),
            CGPoint(x: 0, y: 51.5), CGPoint(x: 24, y: 63), CGPoint(x: 0, y: 74.5),
        ]
        let lines: [OutlinePath.Element] = points.dropFirst().map { .line(to: $0) }
        let expected: [OutlinePath.Element] = [.move(to: points[0])] + lines + [.close]
        #expect(path.elements == expected)
        let aspect: CGFloat = 88.0 / 126.0
        #expect(OutlinePath.launchMarkAspect == aspect)
    }

    @Test func theRingStartsAtTwelveAndRunsClockwiseOnceInsideTheStroke() {
        let path = StatusGlyphGeometry.ringPath(in: CGRect(x: 0, y: 0, width: 10, height: 12), thickness: 2)
        let start: CGFloat = .pi / 2
        let end: CGFloat = start - 2 * .pi
        let expected: [OutlinePath.Element] = [
            .arc(center: CGPoint(x: 5, y: 6), radius: 4, startAngle: start, endAngle: end, clockwise: true),
        ]
        #expect(path.elements == expected)
    }

    @Test func theCheckIsTwoStrokesFromTheLeftMiddle() {
        let path = StatusGlyphGeometry.checkPath(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let expected: [OutlinePath.Element] = [
            .move(to: CGPoint(x: 0, y: 50)), .line(to: CGPoint(x: 38, y: 12)), .line(to: CGPoint(x: 100, y: 100)),
        ]
        #expect(path.elements == expected)
    }

    @Test func dotsAreEllipsesAndBarsArePillsInTheirOwnFrame() {
        let frame = CGRect(x: 7, y: 3, width: 4, height: 10)
        let own = CGRect(x: 0, y: 0, width: 4, height: 10)
        let dot: [OutlinePath.Element] = [.ellipse(in: own)]
        let bar: [OutlinePath.Element] = [.roundedRect(in: own, cornerWidth: 2, cornerHeight: 2)]
        #expect(StatusGlyphGeometry.repeatedElementPath(frame, bars: false).elements == dot)
        #expect(StatusGlyphGeometry.repeatedElementPath(frame, bars: true).elements == bar)
    }
}

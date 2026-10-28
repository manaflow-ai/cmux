import CmuxNextCompat
import Foundation
import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// ``OutlinePath`` records the `CGMutablePath` calls in Foundation geometry alone (it builds on Linux),
/// and on Apple platforms ``OutlinePath/cgPath`` replays them into the same `CGPath` the calls give.
@Suite struct OutlinePathTests {
    @Test func addLinesIsAMoveThenALineToEachNextPoint() {
        var path = OutlinePath()
        path.addLines(between: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), CGPoint(x: 5, y: 6)])
        path.closeSubpath()
        let expected: [OutlinePath.Element] = [
            .move(to: CGPoint(x: 1, y: 2)), .line(to: CGPoint(x: 3, y: 4)), .line(to: CGPoint(x: 5, y: 6)), .close,
        ]
        #expect(path.elements == expected)
    }

    @Test func addLinesWithNoPointsAddsNothing() {
        var path = OutlinePath()
        path.addLines(between: [])
        #expect(path.elements.isEmpty)
    }

    @Test func eachCallIsOneElementInOrder() {
        let center = CGPoint(x: 5, y: 5)
        let start: CGFloat = .pi / 2
        let end: CGFloat = start - 2 * .pi
        let oval = CGRect(x: 0, y: 0, width: 4, height: 2)
        let pill = CGRect(x: 0, y: 0, width: 4, height: 8)
        var path = OutlinePath()
        path.addArc(center: center, radius: 4, startAngle: start, endAngle: end, clockwise: true)
        path.addEllipse(in: oval)
        path.addRoundedRect(in: pill, cornerWidth: 2, cornerHeight: 2)
        let expected: [OutlinePath.Element] = [
            .arc(center: center, radius: 4, startAngle: start, endAngle: end, clockwise: true),
            .ellipse(in: oval),
            .roundedRect(in: pill, cornerWidth: 2, cornerHeight: 2),
        ]
        #expect(path.elements == expected)
    }

    @Test func theWindowListNeverListsWindowZero() {
        #expect(WindowServerList().windows(above: 0).isEmpty)
    }

    #if canImport(CoreGraphics)
    @Test func cgPathIsThePathTheSameCallsBuild() {
        let center = CGPoint(x: 5, y: 5)
        let start: CGFloat = .pi / 2
        let end: CGFloat = start - 2 * .pi
        var outline = OutlinePath()
        let expected = CGMutablePath()
        outline.move(to: CGPoint(x: 0, y: 5))
        expected.move(to: CGPoint(x: 0, y: 5))
        outline.addLine(to: CGPoint(x: 4, y: 1))
        expected.addLine(to: CGPoint(x: 4, y: 1))
        outline.addArc(center: center, radius: 4, startAngle: start, endAngle: end, clockwise: true)
        expected.addArc(center: center, radius: 4, startAngle: start, endAngle: end, clockwise: true)
        outline.closeSubpath()
        expected.closeSubpath()
        outline.addLines(between: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 3, y: 1)])
        expected.addLines(between: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 3, y: 1)])
        #expect(outline.cgPath == expected)
    }

    @Test func oneShapePathsMatchTheirCGPathInitializers() {
        let rect = CGRect(x: 0, y: 0, width: 4, height: 9)
        var ellipse = OutlinePath()
        ellipse.addEllipse(in: rect)
        #expect(ellipse.cgPath == CGPath(ellipseIn: rect, transform: nil))
        var rounded = OutlinePath()
        rounded.addRoundedRect(in: rect, cornerWidth: 2, cornerHeight: 2)
        #expect(rounded.cgPath == CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
    }
    #endif
}

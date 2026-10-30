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
        // Element by element, each point within a millionth of a point: the old construction's
        // `addLines(between:)` and the replayed move and line calls print the same path but need not be
        // bit-equal (`CGPath ==` compares the stored floats; fleet run a2ab5dc2).
        #expect(Self.same(Self.elements(of: OutlinePath.launchMark(in: rect).cgPath), Self.elements(of: expected)))
    }

    /// One path element: its type and its points.
    private struct Element {
        let type: CGPathElementType
        let points: [CGPoint]
    }

    private static func same(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.type == right.type && left.points.count == right.points.count
                && zip(left.points, right.points).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }
        }
    }

    private static func elements(of path: CGPath) -> [Element] {
        var elements: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count = switch element.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            elements.append(Element(type: element.type, points: (0..<count).map { unsafe element.points[$0] }))
        }
        return elements
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

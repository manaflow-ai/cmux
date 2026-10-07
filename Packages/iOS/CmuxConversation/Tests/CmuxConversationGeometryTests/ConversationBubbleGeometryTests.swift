import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Reference outlines are `CKBalloonShapeLayer` paths dumped from ChatKit on
/// iOS 26.3 (iPhone 17 Pro simulator, Large text, radius 20.1436), as
/// "x,y" points of every curve (controls and ends) in the layer's space.
@Suite struct ConversationBubbleGeometryTests {
    private static let r: CGFloat = 20.1435546875

    private func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            let count: Int
            switch e.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            for i in 0..<count { result.append(e.points[i]) }
        }
        return result
    }

    private func parse(_ reference: String) -> [CGPoint] {
        reference.split(whereSeparator: \.isWhitespace).map { pair in
            let xy = pair.split(separator: ",").map { CGFloat(Double($0)!) }
            return CGPoint(x: xy[0], y: xy[1])
        }
    }

    /// Every ChatKit point lies on one of ours and every one of ours on one
    /// of ChatKit's, within `tolerance` points (a third of a pixel at 3x).
    private func expectMatches(_ path: CGPath, _ reference: String, tolerance: CGFloat = 0.11, sourceLocation: SourceLocation = #_sourceLocation) {
        let ours = points(path)
        let theirs = parse(reference)
        func near(_ p: CGPoint, _ set: [CGPoint]) -> Bool {
            set.contains { abs($0.x - p.x) <= tolerance && abs($0.y - p.y) <= tolerance }
        }
        for p in theirs where !near(p, ours) {
            Issue.record("ChatKit point \(p) missing from our outline", sourceLocation: sourceLocation)
        }
        for p in ours where !near(p, theirs) {
            Issue.record("our point \(p) is not on ChatKit's outline", sourceLocation: sourceLocation)
        }
    }

    @Test func singleLineTailedTrailingMatchesChatKit() {
        let path = ConversationBubbleGeometry.iOSPath(in: CGRect(x: 0, y: 0, width: 109.02392578125, height: 40.287109375), side: .trailing, tail: true, radius: Self.r)
        expectMatches(path, """
        0.000,20.144 0.000,17.591 0.485,15.061 1.430,12.689 3.478,7.549 7.510,3.478 12.721,1.509
        17.493,0.000 21.926,0.000 30.793,0.000 78.231,0.000 87.098,0.000 91.531,0.000 96.303,1.509
        101.514,3.405 105.618,7.549 107.594,12.689 108.539,15.061 109.024,17.591 109.024,20.144
        109.024,24.481 107.599,28.703 104.967,32.153 103.901,33.551 102.669,34.784 101.309,35.832
        99.370,37.344 98.531,38.921 98.531,40.694 98.531,41.885 98.742,43.062 100.453,45.310
        101.274,46.388 100.450,47.488 99.167,47.001 96.528,45.998 93.522,44.174 90.890,42.228
        88.531,40.483 87.902,40.307 86.796,40.300 30.793,40.287 21.926,40.287 17.493,40.287 12.721,38.778
        7.510,36.882 3.405,32.738 1.430,27.598 0.485,25.226 0.000,22.697
        """)
    }

    @Test func threeLineTailedAndTaillessMatchChatKit() {
        let rect = CGRect(x: 0, y: 0, width: 314.5, height: 80.287109375)
        let common = """
        0.000,30.793 0.000,21.926 0.000,17.493 1.509,12.721 3.405,7.510 7.510,3.405 12.721,1.509
        17.493,0.000 21.926,0.000 30.793,0.000 283.707,0.000 292.574,0.000 297.007,0.000 301.779,1.509
        306.990,3.405 311.095,7.510 312.991,12.721 314.500,17.493 314.500,21.926 314.500,30.793 314.500,49.494
        30.793,80.287 21.926,80.287 17.493,80.287 12.721,78.778 7.510,76.882 3.405,72.777 1.509,67.567
        0.000,62.794 0.000,58.361 0.000,49.494
        """
        expectMatches(ConversationBubbleGeometry.iOSPath(in: rect, side: .trailing, tail: true, radius: Self.r), common + """

        314.500,64.481 313.075,68.703 310.443,72.153 309.377,73.551 308.146,74.784 306.785,75.832
        304.846,77.344 304.007,78.921 304.007,80.694 304.007,81.885 304.218,83.062 305.929,85.310
        306.750,86.388 305.926,87.488 304.643,87.001 302.004,85.998 298.999,84.174 296.366,82.228
        294.007,80.483 293.378,80.307 292.272,80.300
        """)
        expectMatches(ConversationBubbleGeometry.iOSPath(in: rect, side: .trailing, tail: false, radius: Self.r), common + """

        314.500,58.361 314.500,62.794 312.991,67.566 311.095,72.777 306.990,76.882 301.779,78.778
        297.007,80.287 292.574,80.287 283.707,80.287
        """)
    }

    /// Two lines leave too little side for the full corner, so ChatKit
    /// blends toward its pill corner.
    @Test func twoLineCornersBlendLikeChatKit() {
        let path = ConversationBubbleGeometry.iOSPath(in: CGRect(x: 0, y: 0, width: 297.974609375, height: 60.287109375), side: .trailing, tail: false, radius: Self.r)
        expectMatches(path, """
        0.000,30.144 0.000,21.662 0.030,17.345 1.504,12.719 3.410,7.512 7.510,3.410 12.721,1.509
        17.493,0.000 21.926,0.000 30.793,0.000 267.182,0.000 276.049,0.000 280.482,0.000 285.254,1.509
        290.465,3.405 294.569,7.512 296.470,12.719 297.945,17.345 297.975,21.662 297.975,30.144
        297.975,38.625 297.945,42.943 296.470,47.568 294.569,52.775 290.465,56.882 285.254,58.778
        280.482,60.287 276.049,60.287 267.182,60.287 30.793,60.287 21.926,60.287 17.493,60.287 12.721,58.778
        7.510,56.882 3.405,52.775 1.504,47.568 0.030,42.943 0.000,38.625
        """)
    }

    /// The minimum 48 pt bubble blends its corners horizontally too.
    @Test func narrowTailedLeadingMatchesChatKit() {
        let path = ConversationBubbleGeometry.iOSPath(in: CGRect(x: 0, y: 0, width: 48, height: 40.287109375), side: .leading, tail: true, radius: Self.r)
        // ChatKit's right-tailed 48 pt bubble, mirrored.
        let trailing = parse("""
        0.000,20.144 0.000,17.591 0.485,15.061 1.430,12.689 3.478,7.549 7.535,3.478 12.700,1.459
        15.942,0.310 19.161,0.000 24.000,0.000 28.839,0.000 32.058,0.310 35.300,1.459 40.465,3.451
        44.549,7.549 46.570,12.689 47.515,15.061 48.000,17.591 48.000,20.144 48.000,24.481 46.575,28.703
        43.943,32.153 42.877,33.551 41.646,34.784 40.285,35.832 38.346,37.344 37.507,38.921 37.507,40.694
        37.507,41.885 37.718,43.062 39.429,45.310 40.250,46.388 39.426,47.488 38.143,47.001 35.504,45.998
        32.499,44.174 29.866,42.228 27.507,40.483 26.878,40.307 25.772,40.300 24.000,40.287 19.161,40.287
        15.942,39.978 12.700,38.828 7.535,36.836 3.451,32.738 1.430,27.598 0.485,25.226 0.000,22.697
        """)
        expectMatches(path, trailing.map { String(format: "%.3f,%.3f", 48 - $0.x, $0.y) }.joined(separator: " "))
    }

    @Test func tailDropScalesWithRadius() {
        #expect(abs(ConversationBubbleGeometry.iOSTailDrop(radius: Self.r) - 6.8337) < 0.001)
        let path = ConversationBubbleGeometry.iOSPath(in: CGRect(x: 0, y: 0, width: 200, height: 45.061), side: .trailing, tail: true, radius: 22.5302734375)
        // ChatKit at XXL: body 45.06 tall, tailed balloon 52.70 tall.
        #expect(abs(path.boundingBoxOfPath.maxY - 52.704) < 0.05)
        #expect(path.boundingBoxOfPath.maxX <= 200)
    }

    /// macOS Messages (Mac Catalyst ChatKit, macOS 26.7) draws the same
    /// outline at its 15 pt radius: a 618.39 x 30 incoming balloon.
    @Test func macOSStyleMatchesCatalystChatKit() {
        let path = ConversationBubbleGeometry.path(
            in: CGRect(x: 0, y: 0, width: 618.38818359375, height: 30), side: .leading, tail: true,
            radius: 15, tailWidth: 0, tailDrop: ConversationBubbleGeometry.iOSTailDrop(radius: 15), style: .macOS
        )
        expectMatches(path, """
        618.388,15.000 618.388,13.099 618.027,11.215 617.323,9.449 615.799,5.621 612.796,2.590 608.916,1.124
        605.362,0.000 602.061,0.000 595.458,0.000 22.930,0.000 16.327,0.000 13.026,0.000 9.472,1.124
        5.592,2.536 2.536,5.621 1.065,9.449 0.361,11.215 0.000,13.099 0.000,15.000 0.000,18.230 1.061,21.374
        3.021,23.943 3.815,24.984 4.732,25.902 5.745,26.682 7.189,27.808 7.813,28.983 7.813,30.303
        7.813,31.190 7.657,32.067 6.383,33.741 5.771,34.543 6.385,35.362 7.340,34.999 9.305,34.253
        11.543,32.895 13.504,31.445 15.260,30.146 15.728,30.015 16.553,30.009 595.458,30.000
        602.061,30.000 605.362,30.000 608.916,28.876 612.796,27.464 615.852,24.379 617.323,20.551
        618.027,18.785 618.388,16.901
        """)
    }
}

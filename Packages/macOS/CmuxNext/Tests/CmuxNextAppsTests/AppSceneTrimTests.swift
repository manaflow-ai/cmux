import AppKit
@testable import CmuxNextApps
import Testing

/// A shape's `trim` parses only `{from?, to, lineCap?}` with the web renderer's clamping, a trimmed
/// circle starts at 12 o'clock, and an untrimmed shape keeps the layer's whole-outline defaults.
@MainActor @Suite struct AppSceneTrimTests {
    private func trim(_ text: String) throws -> AppSceneTrim? {
        AppSceneTrim(try AppJSON.parse(text))
    }

    @Test func parsesAndClamps() throws {
        let ring = try #require(try trim(##"{"to": 0.7, "lineCap": "round"}"##))
        #expect(ring == AppSceneTrim(try AppJSON.parse(##"{"from": 0, "to": 0.7, "lineCap": "round"}"##)))
        #expect(ring.from == 0 && abs(ring.to - 0.7) < 1e-9 && ring.lineCap == .round)
        let clamped = try #require(try trim(##"{"from": 0.8, "to": 1.5, "lineCap": "square"}"##))
        #expect(abs(clamped.from - 0.8) < 1e-9 && clamped.to == 1 && clamped.lineCap == .butt)
        let crossed = try #require(try trim(##"{"from": 0.6, "to": 0.2}"##))
        #expect(abs(crossed.from - 0.6) < 1e-9 && abs(crossed.to - 0.6) < 1e-9)
    }

    @Test(arguments: [##"null"##, ##"0.5"##, ##"{}"##, ##"{"from": 0.2}"##, ##"{"to": "0.5"}"##])
    func refusesAValueWithNoFiniteTo(_ text: String) throws {
        #expect(try trim(text) == nil)
    }

    @Test func aTrimmedCircleStartsAtTwelveOClock() {
        // y-down (a flipped view's layer): 12 o'clock is the smallest y.
        let down = AppSceneTrim.circle(center: CGPoint(x: 20, y: 20), radius: 10, yDown: true)
        #expect(abs(down.currentPointAfterMove.x - 20) < 1e-6 && abs(down.currentPointAfterMove.y - 10) < 1e-6)
        let up = AppSceneTrim.circle(center: CGPoint(x: 20, y: 20), radius: 10, yDown: false)
        #expect(abs(up.currentPointAfterMove.x - 20) < 1e-6 && abs(up.currentPointAfterMove.y - 30) < 1e-6)
    }

    @Test func theViewSetsStrokeStartAndEndOnlyWhenTrimmed() throws {
        func shapeLayer(_ props: [String: AppJSON]) -> CAShapeLayer? {
            let view = AppSceneShapeNSView(id: "c", node: AppSceneNode(type: .circle, props: props))
            view.configure(AppSceneNode(type: .circle, props: props))
            view.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            view.layoutSubtreeIfNeeded()
            view.layout()
            return view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
        }
        let ring = try #require(shapeLayer(["size": 44, "stroke": "accent", "strokeWidth": 6,
                                            "trim": .object(["from": 0.1, "to": 0.7, "lineCap": "round"])]))
        #expect(abs(ring.strokeStart - 0.1) < 1e-6 && abs(ring.strokeEnd - 0.7) < 1e-6)
        #expect(ring.lineCap == .round)
        let empty = try #require(shapeLayer(["size": 44, "stroke": "accent", "trim": .object(["to": 0, "lineCap": "round"])]))
        #expect(empty.strokeEnd == 0 && empty.lineCap == .butt)
        let plain = try #require(shapeLayer(["size": 44, "stroke": "accent", "strokeWidth": 6]))
        #expect(plain.strokeStart == 0 && plain.strokeEnd == 1 && plain.lineCap == .butt)
        // No stroke: nothing to trim, so the outline stays whole.
        let filled = try #require(shapeLayer(["size": 44, "fill": "accent", "trim": .object(["to": 0.5])]))
        #expect(filled.strokeEnd == 1)
    }
}

private extension CGPath {
    /// The point the path's first move goes to (where a trim counts from).
    var currentPointAfterMove: CGPoint {
        var first: CGPoint?
        applyWithBlock { element in
            if first == nil, element.pointee.type == .moveToPoint { first = element.pointee.points[0] }
        }
        return first ?? .zero
    }
}

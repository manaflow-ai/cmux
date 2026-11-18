import AppKit
@testable import CmuxNextApps
import Testing

/// A scene gradient (`background`, a shape's `fill`) parses only the documented shape, and its
/// geometry follows CSS: 0 degrees points up, 180 (the default) down, 90 right.
@MainActor @Suite struct AppSceneGradientTests {
    private func gradient(_ text: String) throws -> AppSceneGradient? {
        AppSceneGradient(try AppJSON.parse(text))
    }

    @Test func parsesLinearAndRadialGradients() throws {
        let linear = try #require(try gradient(##"{"linear": {"colors": ["#112233", "success", "#44556680"], "angle": 90}}"##))
        #expect(linear.colors.count == 3)
        guard case .linear(let angle) = linear.kind else { Issue.record("not linear"); return }
        #expect(angle == 90)
        let defaulted = try #require(try gradient(##"{"linear": {"colors": ["#112233", "#445566"]}}"##))
        guard case .linear(let down) = defaulted.kind else { Issue.record("not linear"); return }
        #expect(down == 180)
        let radial = try #require(try gradient(##"{"radial": {"colors": ["#112233", "#445566"]}}"##))
        guard case .radial = radial.kind else { Issue.record("not radial"); return }
    }

    @Test(arguments: [
        ##""#112233""##,
        ##"{"linear": {"colors": ["#112233"]}}"##,
        ##"{"linear": {"colors": ["#112233", "#112233", "#112233", "#112233", "#112233", "#112233", "#112233", "#112233", "#112233"]}}"##,
        ##"{"linear": {"colors": ["#112233", "red"]}}"##,
        ##"{"linear": {"colors": ["#112233", "#445566"], "angle": "90deg"}}"##,
        ##"{"linear": {"colors": ["#112233", "#445566"], "stops": [0, 1]}}"##,
        ##"{"radial": {"colors": ["#112233", "#445566"], "angle": 90}}"##,
        ##"{"conic": {"colors": ["#112233", "#445566"]}}"##,
        ##"{"linear": {"colors": ["#112233", "#445566"]}, "radial": {"colors": ["#112233", "#445566"]}}"##,
    ])
    func refusesAnythingElse(_ text: String) throws {
        #expect(try gradient(text) == nil)
    }

    @Test func pointsFollowCSSAngles() throws {
        let layer = CAGradientLayer()
        let size = CGSize(width: 100, height: 100)
        // 180 (down) on a y-down box: from the top edge's middle to the bottom's.
        try #require(try gradient(##"{"linear": {"colors": ["#000000", "#FFFFFF"]}}"##)).apply(to: layer, size: size, yDown: true)
        #expect(abs(layer.startPoint.x - 0.5) < 1e-9 && abs(layer.startPoint.y - 0) < 1e-9)
        #expect(abs(layer.endPoint.x - 0.5) < 1e-9 && abs(layer.endPoint.y - 1) < 1e-9)
        // The same in a y-up space flips the unit points, so it still runs top to bottom on screen.
        try #require(try gradient(##"{"linear": {"colors": ["#000000", "#FFFFFF"]}}"##)).apply(to: layer, size: size, yDown: false)
        #expect(abs(layer.startPoint.y - 1) < 1e-9 && abs(layer.endPoint.y - 0) < 1e-9)
        // 90 (right): left edge to right edge.
        try #require(try gradient(##"{"linear": {"colors": ["#000000", "#FFFFFF"], "angle": 90}}"##)).apply(to: layer, size: size, yDown: true)
        #expect(abs(layer.startPoint.x - 0) < 1e-9 && abs(layer.endPoint.x - 1) < 1e-9)
        #expect(abs(layer.startPoint.y - 0.5) < 1e-9)
        // 45 on a square: corner to corner, like CSS's gradient line.
        try #require(try gradient(##"{"linear": {"colors": ["#000000", "#FFFFFF"], "angle": 45}}"##)).apply(to: layer, size: size, yDown: true)
        #expect(abs(layer.startPoint.x - 0) < 1e-9 && abs(layer.startPoint.y - 1) < 1e-9)
        #expect(abs(layer.endPoint.x - 1) < 1e-9 && abs(layer.endPoint.y - 0) < 1e-9)
        #expect(layer.type == .axial)
        try #require(try gradient(##"{"radial": {"colors": ["#000000", "#FFFFFF"]}}"##)).apply(to: layer, size: size, yDown: true)
        #expect(layer.type == .radial)
        #expect(layer.colors?.count == 2)
    }
}

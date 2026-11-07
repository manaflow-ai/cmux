import Foundation
import QuartzCore
import Testing
@testable import CmuxSpinner

/// Every spinner turns once per the shared period (Leo 2026-11-07: "Let's have all our spinners go
/// at that speed."), on the shared phase.
@Suite struct CmuxSpinnerTests {
    /// The token motion-scale.json holds, read from the source so a stale generated copy fails.
    private static func tokenSeconds() throws -> Double {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("schemas/motion-scale/motion-scale.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spinner = try #require(json["spinner"] as? [String: Any])
        return try #require(spinner["ms"] as? Double) / 1000
    }

    @Test func periodIsTheSharedToken() throws {
        #expect(CmuxSpinnerPeriod().seconds == (try Self.tokenSeconds()))
        #expect(CmuxSpinnerPeriod().seconds == 2)
    }

    @Test func oneTurnPerPeriodClockwise() {
        let spin = CmuxSpinnerLayer.turnAnimation(period: CmuxSpinnerPeriod())
        #expect(spin.keyPath == "transform.rotation.z")
        #expect(spin.duration == CmuxSpinnerPeriod().seconds)
        #expect(spin.repeatCount == .infinity)
        #if os(macOS)
        #expect((spin.toValue as? CGFloat) == -2 * .pi)
        #else
        #expect((spin.toValue as? CGFloat) == 2 * .pi)
        #endif
    }

    @Test func turningLayerUsesThePeriod() throws {
        let layer = CmuxSpinnerLayer()
        layer.turn(true)
        let spin = try #require(layer.animation(forKey: CmuxSpinnerLayer.turnKey))
        #expect(spin.duration == 2)
        layer.turn(false)
        #expect(!layer.isTurning)
    }

    @Test func phaseIsUnixTimeModPeriod() {
        let period = CmuxSpinnerPeriod()
        // 1000.5 s into Unix time is 0.5 s into a 2 s turn: the turn began 0.5 s ago.
        #expect(abs(CmuxSpinnerLayer.beginTime(period: period, mediaTime: 100, unixTime: 1000.5) - 99.5) < 1e-9)
        // Two spinners started at different moments share one phase.
        let early = CmuxSpinnerLayer.beginTime(period: period, mediaTime: 500, unixTime: 7000.25)
        let late = CmuxSpinnerLayer.beginTime(period: period, mediaTime: 500.37, unixTime: 7000.62)
        #expect(abs((early - late).truncatingRemainder(dividingBy: 2)) < 1e-9)
    }
}

import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo 2026-10-13 (cx-sya4n): nothing in cmux flashes faster than twice a second, in any mode:
/// every on-off-on cycle of an opacity flash lasts at least 0.5 s, also at the fastest Debug
/// Settings loop periods and the fast animation speed. The pane attention ring blinked about
/// three times a second (0.3 s per blink) and the flash verb faster.
@MainActor @Suite(.serialized) struct BlinkRateCapTests {
    static let shortestCycle: TimeInterval = 0.5

    /// The shortest on-off-on cycle of an opacity animation, in seconds; nil when it never
    /// comes back on.
    static func shortestFlashCycle(_ animation: CAAnimation) -> TimeInterval? {
        if let group = animation as? CAAnimationGroup { return (group.animations ?? []).compactMap(shortestFlashCycle).min() }
        if let basic = animation as? CABasicAnimation, basic.keyPath == "opacity" {
            // There and back is one cycle.
            if basic.autoreverses { return basic.duration * 2 }
            return basic.repeatCount > 1 || basic.repeatDuration > basic.duration ? basic.duration : nil
        }
        guard let frames = animation as? CAKeyframeAnimation, frames.keyPath == "opacity",
              let values = frames.values?.compactMap({ ($0 as? NSNumber)?.doubleValue }), values.count > 1,
              let high = values.max(), let low = values.min(), high > low else { return nil }
        let times = frames.keyTimes.map { $0.map { $0.doubleValue * frames.duration } }
            ?? values.indices.map { Double($0) / Double(values.count - 1) * frames.duration }
        let middle = (high + low) / 2
        var lastOn: TimeInterval?
        var wentOff = false
        var shortest: TimeInterval?
        for (value, time) in zip(values, times) {
            if value > middle {
                if let lastOn, wentOff { shortest = min(shortest ?? .infinity, time - lastOn) }
                lastOn = time
                wentOff = false
            } else if lastOn != nil {
                wentOff = true
            }
        }
        if frames.repeatCount > 1, let first = zip(values, times).first(where: { $0.0 > middle })?.1, let lastOn {
            shortest = min(shortest ?? .infinity, frames.duration - lastOn + first)
        }
        return shortest
    }

    @Test func nothingFlashesFasterThanTwiceASecond() throws {
        // The fastest loop periods Debug Settings allows (a set value clamps to the tunable's range).
        let store = TunableStore.shared
        store.register(MotionTunables.all)
        store.activate(file: nil)
        let keys = MotionLoop.allCases.compactMap { MotionTunables.loops[$0]?.key }
        for key in keys { store.set(key, .number(0)) }
        defer { store.reset(keys) }
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.animationSpeed = .fast
        defer { DesignSettings.shared.animationSpeed = speed }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        var flashes: [(String, CAAnimation?)] = [("flash verb", Motion.indicators.flashAnimation()),
                                                  ("status pulse", Motion.indicators.pulseAnimation(low: 0))]
        var attention = AttentionSettings()
        for look in AttentionHighlightLook.allCases {
            attention.style = .pulse
            flashes.append(("attention pulse \(look)", Motion.indicators.attentionAnimation(attention, look: look)))
            attention.style = .blink
            for count in [2, AttentionSettings.blinkRange.upperBound] {
                attention.blinkCount = count
                flashes.append(("attention \(count) blinks \(look)", Motion.indicators.attentionAnimation(attention, look: look)))
                flashes.append(("dismiss \(count) blinks \(look)", Motion.indicators.attentionDismissAnimation(attention, look: look)))
            }
        }
        for (name, animation) in flashes {
            let animation = try #require(animation, "\(name): no animation")
            let cycle = try #require(Self.shortestFlashCycle(animation), "\(name) never flashes")
            #expect(cycle >= Self.shortestCycle - 1e-6, "\(name) flashes every \(cycle) s")
        }
    }
}

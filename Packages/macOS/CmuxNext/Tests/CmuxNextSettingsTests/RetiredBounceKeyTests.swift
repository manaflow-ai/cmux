import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// No bounce in any motion (Lawrence 2026-11-10; plans/cmux-next/motion-first-principles-DESIGN.md,
/// principle 5: position never passes its target). `ui.animations.bounce` is a retired key: a
/// cmux.json that still has it loads with no diagnostic, whatever its value, and no spring the
/// app resolves from that file passes its target.
@MainActor @Suite(.serialized) struct RetiredBounceKeyTests {
    private static let path = ["ui", "animations", "bounce"]
    private static let key = "ui.animations.bounce"

    private func snapshot(bounce: JSONValue?, speed: String? = nil) -> CmuxConfigSnapshot {
        var ui: [String: JSONValue] = [:]
        if let bounce { ui["animations"] = .object(["bounce": bounce]) }
        if let speed { ui["animationSpeed"] = .string(speed) }
        return CmuxConfigSnapshot.parse(.object(["ui": .object(ui)]), validDensities: [], validMetrics: [])
    }

    /// An old file's value, and values the key never took: none is a diagnostic (a diagnostic
    /// shows a notice at every load, for a key the person can no longer fix in Settings).
    @Test func anOldBounceValueLoadsWithoutADiagnostic() {
        for value in [JSONValue.string("subtle"), .string("none"), .string("wild"), .number(3), .bool(true), .object([:])] {
            let parsed = snapshot(bounce: value)
            #expect(!parsed.diagnostics.contains { $0.path.hasPrefix(Self.key) }, "diagnostic for ui.animations.bounce = \(value)")
            #expect(parsed.retiredKeys == [Self.key], "ui.animations.bounce = \(value) is not listed as retired")
        }
    }

    /// Settings offers no row for it, and a write says it was removed.
    @Test func settingsHasNoBounceRow() {
        #expect(SettingsSchema.descriptor(for: Self.path) == nil)
        #expect(SettingsSchema.isRetired(Self.path))
    }

    /// The file through the applier to the policy every gate reads (`Motion.basePolicy`): with
    /// `"bounce": "subtle"` in the file, a 200 pt move on each spring that gives or takes room,
    /// sampled at 480 Hz, never passes its target by more than 1e-6 of the travel.
    @Test func aFileThatAsksForBounceGetsNone() {
        let design = DesignSettings.shared
        let saved = (design.animationSpeed, design.enabledAnimations, design.paneAnimations, design.calmMode,
                     design.animationsEnabled, design.disabledAnimationCategories, design.hoverCardsEnabled)
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        defer {
            // The same file without the key takes back whatever the key set, then the saved switches.
            _ = applier.apply(snapshot(bounce: nil))
            (design.animationSpeed, design.enabledAnimations, design.paneAnimations, design.calmMode,
             design.animationsEnabled, design.disabledAnimationCategories, design.hoverCardsEnabled) = saved
        }
        let travel: CGFloat = 200
        for speed in ["fast", "normal"] {
            _ = applier.apply(snapshot(bounce: .string("subtle"), speed: speed))
            #expect(design.animationSpeed.rawValue == speed)
            let policy = Motion.basePolicy
            for token in [MotionSpring.move, .appear, .disappear, .tabOpen] {
                let spring = policy.spring(token)
                var value = SpringValue(0)
                value.target = travel
                var farthest: CGFloat = 0
                for _ in 0..<(3 * 480) {
                    value.step(1.0 / 480.0, parameters: spring)
                    farthest = max(farthest, value.value - travel)
                }
                #expect(farthest <= travel * 1e-6,
                        "\(token.rawValue) at speed \(speed) passes its target by \(farthest) pt of \(travel) (damping \(spring.dampingFraction))")
                #expect(abs(value.value - travel) < 0.25, "\(token.rawValue) at speed \(speed) is not at rest after 3 s")
            }
        }
    }
}

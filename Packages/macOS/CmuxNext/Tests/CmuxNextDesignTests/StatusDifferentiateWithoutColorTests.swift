@testable import CmuxNextAppearance
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import Testing

/// Differentiate Without Color (pro audit 16): with the system option on, no two status states read
/// apart by color alone. The default Codex-like set draws done (blue) and waiting for you (orange) as
/// the same dot, so a person who cannot tell the tints apart cannot tell a finished agent from one
/// that needs them. The option draws the static look, where each state has its own shape, natively
/// and on every web page (`data-status-indicators`), and it follows the option live.
@MainActor @Suite(.serialized) struct StatusDifferentiateWithoutColorTests {
    /// The states a person acts on differently: none may share a shape with another.
    static let states: [StatusIndicatorState] = [.waiting(kind: nil), .waiting(kind: .permission), .error, .success]

    @Test(arguments: StatusIconSet.allCases)
    func noTwoStatesShareAShape(_ set: StatusIconSet) {
        let config = StatusIndicatorConfig(iconSet: set, differentiateWithoutColor: true)
        let glyphs = Self.states.map {
            StatusIndicatorPlan.make($0, style: .arc, animates: true, set: config.iconSet, isStatic: config.isStatic,
                                     staticShapes: config.drawsShapes, working: config.workingLook).glyph
        }
        #expect(Set(glyphs).count == Self.states.count, "\(set): two states differ only by color: \(glyphs)")
    }

    @Test func theConfigFollowsTheSystemOptionLive() {
        let signals = DesignSettings.shared.signals
        let before = signals.displayOverride
        defer {
            signals.displayOverride = before
            signals.refreshDisplayOptions()
        }
        signals.displayOverride = AppearanceSignals.DisplayOptions(differentiateWithoutColor: false)
        signals.refreshDisplayOptions()
        #expect(!StatusIndicatorAppearance.shared.config.differentiateWithoutColor)
        signals.displayOverride = AppearanceSignals.DisplayOptions(differentiateWithoutColor: true)
        signals.refreshDisplayOptions()
        #expect(StatusIndicatorAppearance.shared.config.differentiateWithoutColor, "the shared config did not hear the option")
        #expect(StatusIndicatorAppearance.shared.config.isStatic)
        let payload = try? JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any]
        #expect(payload?["statusIndicators"] as? String == "static", "web pages still draw done and waiting as one dot")
    }
}

@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// RFD 0207 "Native toast glass variant": Debug Settings > Toasts > Glass offers the glass every other native
/// overlay draws, and the default stays the veil-tinted glass until Leo says otherwise.
struct CmuxToastGlassTests {
    @Test func oneChoiceIsTheOtherOverlaysGlass() {
        #expect(CmuxToastGlass.liquid.variant == OverlayGlassVariant.picked)
        #expect(CmuxToastGlass.liquid.variant == .appKitRegular)
    }

    @Test func theDefaultIsUnchanged() {
        #expect(CmuxToastTunables.glass.defaultValue == .liquidVeil)
    }
}

import CmuxNextDesign
import Testing

/// Instrument's names resolve, from outside the module, to the views the app already draws.
struct InstrumentTests {
    @Test func namesAreTheExistingTypes() {
        #expect(Instrument.Button.self == ClickableButton.self)
        #expect(Instrument.ButtonStyle.self == CmuxPressFillButtonStyle.self)
        #expect(Instrument.Row.self == PopupRowView.self)
        #expect(Instrument.Panel.self == CardSurfaceView.self)
        #expect(Instrument.Glass.self == GlassPanelView.self)
        #expect(Instrument.GlassLevel.self == GlassLevel.self)
        #expect(Instrument.GlassMenu.self == GlassMenu.self)
        #expect(Instrument.Tooltip.self == TooltipPresenter.self)
        #expect(Instrument.Motion.self == Motion.self)
    }

    @Test func versionMatchesTheWebKit() {
        #expect(Instrument.version == "0.1.0")
    }
}

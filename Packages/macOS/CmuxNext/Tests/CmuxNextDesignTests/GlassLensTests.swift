import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The glass mode pages draw and the theme that carries it (plans/cmux-next/glass-lens-DESIGN.md):
/// `appearance.glass` unless Reduce Transparency or Low Power Mode make it plain, sent as `glass`
/// in the theme payload and set as `data-glass` by the bootstrap, which also defines the backdrop push.
@MainActor @Suite struct GlassLensTests {
    @Test func reduceTransparencyAndLowPowerModeDrawPlainGlass() {
        for mode in GlassLensMode.allCases {
            #expect(mode.effective(reduceTransparency: false, lowPowerMode: false) == mode)
            #expect(mode.effective(reduceTransparency: true, lowPowerMode: false) == .plain)
            #expect(mode.effective(reduceTransparency: false, lowPowerMode: true) == .plain)
        }
        #expect(GlassLensMode.lens.refracts && GlassLensMode.spectrum.refracts && !GlassLensMode.plain.refracts)
    }

    @Test func theCurrentModeReadsTheSettingAndBothSystemSwitches() {
        let settings = DesignSettings()
        #expect(settings.glass == .lens)
        settings.glass = .spectrum
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let reduced = ReduceTransparency(system: { true }, changes: NotificationCenter())
        #expect(GlassLensMode.current(settings: settings, reduceTransparency: clear, lowPower: LowPowerMode(enabled: false)) == .spectrum)
        #expect(GlassLensMode.current(settings: settings, reduceTransparency: reduced, lowPower: LowPowerMode(enabled: false)) == .plain)
        let lowPower = LowPowerMode(enabled: false)
        lowPower.override = true
        #expect(GlassLensMode.current(settings: settings, reduceTransparency: clear, lowPower: lowPower) == .plain)
    }

    @Test func thePayloadCarriesTheGlassMode() throws {
        for mode in GlassLensMode.allCases {
            let json = WebTheme(.unresolved, glass: mode).payloadJSON
            let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(payload["glass"] as? String == mode.rawValue)
        }
        #expect(WebTheme(.unresolved, glass: .plain) != WebTheme(.unresolved, glass: .lens))
    }

    @Test func theBootstrapSetsDataGlassAndDefinesTheBackdropPush() {
        let script = WebTheme.bootstrapScript
        #expect(script.contains("root.setAttribute('data-glass', payload.glass)"))
        #expect(script.contains("backdrop: function (partial)"))
        #expect(script.contains("window.cmuxBackdropState = next"))
        #expect(script.contains("Object.assign({}, window.cmuxBackdropState || {})"))
        #expect(script.contains("window.dispatchEvent(new Event('cmux-backdrop'))"))
        // The gallery reads the literal as JavaScript: no Swift escapes in it.
        #expect(!script.contains("\\"))
    }
}

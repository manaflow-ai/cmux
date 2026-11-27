import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// The glass mode pages draw and the theme that carries it (plans/cmux-next/glass-lens-DESIGN.md):
/// the Debug choice `glass.lens` unless Reduce Transparency or Low Power Mode make it plain, sent as `glass`
/// in the theme payload and set as `data-glass` by the bootstrap, which also defines the backdrop push.
@MainActor @Suite struct GlassLensTests {
    /// Leo 2026-10-21: the lens is a toggle to see and feel; the palette flips it on and off.
    @Test func theToggleTurnsTheLensOnFromPlainAndOffFromEitherRefractingMode() {
        #expect(GlassLensMode.plain.lensToggled == .lens)
        #expect(GlassLensMode.lens.lensToggled == .plain)
        #expect(GlassLensMode.spectrum.lensToggled == .plain)
        #expect(GlassLensMode.plain.lensToggled.lensToggled == .plain)
    }

    @Test func reduceTransparencyAndLowPowerModeDrawPlainGlass() {
        for mode in GlassLensMode.allCases {
            #expect(mode.effective(reduceTransparency: false, lowPowerMode: false) == mode)
            #expect(mode.effective(reduceTransparency: true, lowPowerMode: false) == .plain)
            #expect(mode.effective(reduceTransparency: false, lowPowerMode: true) == .plain)
        }
        #expect(GlassLensMode.lens.refracts && GlassLensMode.spectrum.refracts && !GlassLensMode.plain.refracts)
    }

    @Test func theCurrentModeReadsTheDebugChoiceAndBothSystemSwitches() {
        let store = TunableStore()
        store.register([GlassLensMode.tunable.descriptor])
        store.activate(file: nil)
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let reduced = ReduceTransparency(system: { true }, changes: NotificationCenter())
        #expect(GlassLensMode.current(store: store, reduceTransparency: clear, lowPower: LowPowerMode(enabled: false)) == .plain)
        GlassLensMode.choose(.spectrum, in: store)
        #expect(GlassLensMode.current(store: store, reduceTransparency: clear, lowPower: LowPowerMode(enabled: false)) == .spectrum)
        #expect(GlassLensMode.current(store: store, reduceTransparency: reduced, lowPower: LowPowerMode(enabled: false)) == .plain)
        let lowPower = LowPowerMode(enabled: false)
        lowPower.override = true
        #expect(GlassLensMode.current(store: store, reduceTransparency: clear, lowPower: lowPower) == .plain)
    }

    /// Plain is the default and stores nothing; Release never activates the store, so it stays plain.
    @Test func choosingPlainClearsTheOverrideAndAnInertStoreStaysPlain() {
        let store = TunableStore()
        store.register([GlassLensMode.tunable.descriptor])
        GlassLensMode.choose(.lens, in: store)
        #expect(GlassLensMode.tunable.value(in: store) == .plain)
        store.activate(file: nil)
        #expect(GlassLensMode.tunable.value(in: store) == .lens)
        GlassLensMode.choose(.plain, in: store)
        #expect(store.overrides[GlassLensMode.tunable.key] == nil)
        #expect(GlassLensMode.tunable.value(in: store) == .plain)
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

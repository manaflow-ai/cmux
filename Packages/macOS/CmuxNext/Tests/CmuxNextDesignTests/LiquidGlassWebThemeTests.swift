@testable import CmuxNextDesign
import Foundation
import Testing

/// `appearance.liquidGlass` off (CMUX-653, Lawrence 2026-11-18: a toggle that removes all liquid
/// glass on web views; off by default since standup 2026-11-19): the web theme sends `glass: "off"`
/// whatever the lens choice, so every page
/// sets `data-glass="off"` and draws its glass surfaces solid; the lens mode is plain, so no
/// wallpaper still is fed; and the change repaints every open page (``WebTheme/pushInputs``).
@MainActor @Suite(.serialized) struct LiquidGlassWebThemeTests {
    private func glass(_ theme: WebTheme) throws -> String? {
        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        return payload["glass"] as? String
    }

    @Test func offSendsOffForEveryLensModeAndOnSendsTheMode() throws {
        let design = DesignSettings.shared
        let before = design.liquidGlass
        defer { design.liquidGlass = before }
        design.liquidGlass = true
        for mode in GlassLensMode.allCases {
            #expect(try glass(WebTheme(.unresolved, glass: mode)) == mode.rawValue)
        }
        design.liquidGlass = false
        for mode in GlassLensMode.allCases {
            #expect(try glass(WebTheme(.unresolved, glass: mode)) == WebTheme.glassOff)
        }
        #expect(try glass(WebTheme(.unresolved)) == "off")
    }

    /// With no setting, the app's design settings say off, so a fresh window's pages draw solid.
    @Test func offIsTheDefault() {
        #expect(DesignSettings().liquidGlass == false)
    }

    /// The lens chosen in Debug draws (and is fed a wallpaper still) only while Liquid Glass is on.
    @Test func offDrawsNoLensEvenWhenTheLensIsChosen() {
        let store = TunableStore()
        store.register([GlassLensMode.tunable.descriptor])
        store.activate(file: nil)
        GlassLensMode.choose(.lens, in: store)
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let power = LowPowerMode(enabled: false)
        #expect(GlassLensMode.current(store: store, reduceTransparency: clear, lowPower: power, liquidGlass: true) == .lens)
        #expect(GlassLensMode.current(store: store, reduceTransparency: clear, lowPower: power, liquidGlass: false) == .plain)
    }

    @Test func turningItOffRepaintsOpenPages() {
        let design = DesignSettings.shared
        let before = design.liquidGlass
        defer { design.liquidGlass = before }
        design.liquidGlass = true
        let onInputs = WebTheme.pushInputs
        design.liquidGlass = false
        #expect(WebTheme.pushInputs != onInputs, "turning it off must repaint every open page")
    }
}

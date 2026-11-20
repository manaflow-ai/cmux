import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// The glass mode pages draw and the theme that carries it (plans/cmux-next/glass-lens-DESIGN.md):
/// the setting `appearance.glass.composer.material` unless Reduce Transparency or Low Power Mode make it plain, sent as `glass`
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

    @Test func theCurrentModeReadsTheChosenModeAndBothSystemSwitches() {
        let clear = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let reduced = ReduceTransparency(system: { true }, changes: NotificationCenter())
        #expect(GlassLensMode.current(chosen: .plain, reduceTransparency: clear, lowPower: LowPowerMode(enabled: false)) == .plain)
        #expect(GlassLensMode.current(chosen: .spectrum, reduceTransparency: clear, lowPower: LowPowerMode(enabled: false)) == .spectrum)
        #expect(GlassLensMode.current(chosen: .spectrum, reduceTransparency: reduced, lowPower: LowPowerMode(enabled: false)) == .plain)
        let lowPower = LowPowerMode(enabled: false)
        lowPower.override = true
        #expect(GlassLensMode.current(chosen: .lens, reduceTransparency: clear, lowPower: lowPower) == .plain)
    }

    /// `appearance.glass.composer.material` names the mode: lens and spectrum refract, anything else
    /// (unset, plain, a native material) is plain glass, the look before the lens.
    @Test func aMaterialNamesTheMode() {
        #expect(GlassLensMode(material: "lens") == .lens)
        #expect(GlassLensMode(material: "spectrum") == .spectrum)
        for plain in [nil, "plain", "frosted", "glass-clear", "translucent", "bogus"] {
            #expect(GlassLensMode(material: plain) == .plain)
        }
    }

    /// The Debug choice is gone: nothing registers `glass.lens` as a tunable, so it cannot shadow the setting.
    @Test func theDebugChoiceIsNoLongerATunable() {
        #expect(!DesignTunables.all.contains { $0.key == GlassLensMode.retiredTunableKey })
    }

    /// The rename: a Debug file that still chose lens or spectrum gives the setting that value once; plain (the
    /// default) or no file moves nothing.
    @Test func aDebugFilesRefractingChoiceMovesIntoTheSetting() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "glass-lens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ value: String) throws -> URL {
            let url = folder.appending(path: "\(value).json")
            try Data("{\"version\": 1, \"values\": {\"glass.lens\": \"\(value)\"}}".utf8).write(to: url)
            return url
        }
        #expect(GlassLensMode.retiredChoice(inDebugFile: try file("lens")) == .lens)
        #expect(GlassLensMode.retiredChoice(inDebugFile: try file("spectrum")) == .spectrum)
        #expect(GlassLensMode.retiredChoice(inDebugFile: try file("plain")) == nil)
        #expect(GlassLensMode.retiredChoice(inDebugFile: folder.appending(path: "missing.json")) == nil)
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

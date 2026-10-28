@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import Testing

/// Every web page hears Energy Saver through the one web theme: `energy: "saver"`
/// in the payload only under the saver, and `data-cmux-energy` on `<html>` from the bootstrap,
/// set with it and removed without it. Off, the payload is what it was before.
@MainActor @Suite(.serialized) struct WebThemeEnergyTests {
    private static func payload() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any])
    }

    @Test func thePayloadCarriesTheSaverOnlyUnderIt() throws {
        let design = DesignSettings.shared
        let before = design.energySaver
        defer { design.energySaver = before }
        design.energySaver = false
        let off = try Self.payload()
        #expect(off["energy"] == nil)
        #expect(WebTheme(.unresolved).energy == nil)
        design.energySaver = true
        let on = try Self.payload()
        #expect(on["energy"] as? String == "saver")
        // The saver adds only its key; the motion mark stays the motion gate's.
        #expect(Set(on.keys) == Set(off.keys).union(["energy"]))
        #expect(on["motion"] as? String == off["motion"] as? String)
        design.energySaver = false
        #expect(try Self.payload()["energy"] == nil)
    }

    @Test func theValueFollowsThePolicysSaver() {
        let policy = MotionPolicy(speed: .fast, reduceMotion: false)
        #expect(WebTheme.energyValue(policy) == nil)
        var saver = policy
        saver.energySaver = true
        #expect(WebTheme.energyValue(saver.for(.web)) == "saver")
    }

    @Test func theBootstrapSetsAndClearsTheAttribute() {
        #expect(WebTheme.bootstrapScript.contains("if (payload.energy) root.setAttribute('data-cmux-energy', payload.energy);"))
        #expect(WebTheme.bootstrapScript.contains("else root.removeAttribute('data-cmux-energy');"))
    }
}

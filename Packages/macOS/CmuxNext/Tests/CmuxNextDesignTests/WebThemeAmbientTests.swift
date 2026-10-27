@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import Testing

/// Feature `pageAmbientSteps` reaches every web page through the one web theme (p14-energy-126):
/// `ambient: "step"` in the payload only with the feature, and `data-cmux-ambient` on `<html>` from
/// the bootstrap, set with it and removed without it. Off, the payload is what it was before.
@MainActor @Suite(.serialized) struct WebThemeAmbientTests {
    private static func payload() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any])
    }

    @Test func thePayloadCarriesTheStepOnlyWithTheFeature() throws {
        let design = DesignSettings.shared
        let before = design.pageAmbientSteps
        defer { design.pageAmbientSteps = before }
        design.pageAmbientSteps = false
        let off = try Self.payload()
        #expect(off["ambient"] == nil)
        #expect(WebTheme(.unresolved).ambient == nil)
        design.pageAmbientSteps = true
        let on = try Self.payload()
        #expect(on["ambient"] as? String == "step")
        // The feature adds only its key.
        #expect(Set(on.keys) == Set(off.keys).union(["ambient"]))
    }

    @Test func theValueFollowsTheFeature() {
        #expect(WebTheme.ambientValue(steps: false) == nil)
        #expect(WebTheme.ambientValue(steps: true) == "step")
    }

    @Test func theBootstrapSetsAndClearsTheAttribute() {
        #expect(WebTheme.bootstrapScript.contains("if (payload.ambient) root.setAttribute('data-cmux-ambient', payload.ambient);"))
        #expect(WebTheme.bootstrapScript.contains("else root.removeAttribute('data-cmux-ambient');"))
    }
}

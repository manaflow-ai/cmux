@testable import CmuxNextDesign
import Foundation
import Testing

/// Every web page hears the static status look through the one web theme (cx-sya4n):
/// `statusIndicators` in the payload, `data-status-indicators` on `<html>` from the bootstrap.
/// Static under Reduce Motion or `appearance.statusIndicator.animation: "static"`.
@MainActor @Suite(.serialized) struct WebThemeStatusIndicatorsTests {
    private static func look() throws -> String? {
        let payload = try #require(JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any])
        return payload["statusIndicators"] as? String
    }

    @Test func thePayloadCarriesTheStaticLook() throws {
        let design = DesignSettings.shared
        let before = design.statusIndicator
        defer {
            design.statusIndicator = before
            Motion.reduceMotionOverride = nil
        }
        Motion.reduceMotionOverride = false
        design.statusIndicator.animation = .animated
        #expect(try Self.look() == "animated")
        design.statusIndicator.animation = .static
        #expect(try Self.look() == "static")
        design.statusIndicator.animation = .animated
        Motion.reduceMotionOverride = true
        #expect(try Self.look() == "static")
    }

    @Test func theBootstrapSetsTheAttribute() {
        #expect(WebTheme.bootstrapScript.contains("root.setAttribute('data-status-indicators', payload.statusIndicators)"))
    }
}

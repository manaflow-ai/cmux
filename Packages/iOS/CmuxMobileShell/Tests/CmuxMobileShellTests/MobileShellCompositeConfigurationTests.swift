import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeConfigurationTests {
    @Test func multiMacAggregationDefaultsOnWithoutDebugBuildFlag() throws {
        let enabled = MobileShellComposite.resolveMultiMacAggregationEnabled(
            environment: [:],
            defaults: try emptyDefaults()
        )

        #expect(enabled)
    }

    @Test func multiMacAggregationCanBeDisabledByOverride() throws {
        let defaults = try emptyDefaults()
        defaults.set(false, forKey: "multiMacAggregation")

        let defaultsDisabled = MobileShellComposite.resolveMultiMacAggregationEnabled(
            environment: [:],
            defaults: defaults
        )
        let environmentDisabled = MobileShellComposite.resolveMultiMacAggregationEnabled(
            environment: ["CMUX_MULTI_MAC_AGGREGATION": "false"],
            defaults: try emptyDefaults()
        )

        #expect(!defaultsDisabled)
        #expect(!environmentDisabled)
    }
}

private func emptyDefaults() throws -> UserDefaults {
    let suiteName = "MobileShellCompositeConfigurationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

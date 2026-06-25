import CMUXMobileCore
import CmuxMobilePairedMac
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

    @Test func automaticSecondaryAggregationCapsBackgroundStreams() throws {
        let macs = try (0..<(MobileShellComposite.maximumAutomaticSecondaryMacSubscriptions + 3)).map { index in
            try pairedMac(id: "mac-\(index)")
        }

        let candidates = MobileShellComposite.secondaryAggregationCandidates(
            from: macs,
            foregroundMacDeviceIDs: ["mac-0"]
        )

        #expect(candidates.count == MobileShellComposite.maximumAutomaticSecondaryMacSubscriptions)
        #expect(candidates.map(\.macDeviceID) == (1...MobileShellComposite.maximumAutomaticSecondaryMacSubscriptions).map { "mac-\($0)" })
    }
}

private func emptyDefaults() throws -> UserDefaults {
    let suiteName = "MobileShellCompositeConfigurationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func pairedMac(id: String) throws -> MobilePairedMac {
    MobilePairedMac(
        macDeviceID: id,
        displayName: id,
        routes: [
            try CmxAttachRoute(
                id: "route-\(id)",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.0.0.1", port: 51000)
            ),
        ],
        createdAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 2),
        isActive: false,
        stackUserID: "user-1",
        teamID: "team-1"
    )
}

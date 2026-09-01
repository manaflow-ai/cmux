import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior-level coverage for pairing guidance and external-URL policy.
@Suite struct MobilePairingFailureGuidanceTests {
    @Test func invalidCodeUsesGenericScanGuidance() {
        // A malformed or unrelated QR is not fixed by an app update. Keep the
        // update action reserved for a recognized stale/future cmux payload.
        let message = MobilePairingFailureCategory.invalidCode.message
        #expect(!message.localizedCaseInsensitiveContains("latest version"))
        #expect(!message.localizedCaseInsensitiveContains("update cmux"))
        #expect(message.localizedCaseInsensitiveContains("Tailscale"))
        #expect(!message.isEmpty)
        #expect(MobilePairingFailureCategory.invalidCode.guidance == nil)
    }

    @Test func unrecognizedVersionTellsUserToUpdateTheApp() {
        // A real cmux QR from a newer Mac whose grammar this build predates: the
        // user must be told to update, not that the code is invalid.
        let message = MobilePairingFailureCategory.unrecognizedVersion.message(buildType: .beta)
        #expect(message.lowercased().contains("newer"))
        #expect(!message.localizedCaseInsensitiveContains("update cmux"))
        let guidance = MobilePairingFailureCategory.unrecognizedVersion.guidance(buildType: .beta)
        #expect(guidance?.localizedCaseInsensitiveContains("latest") == true)
        #expect(guidance?.localizedCaseInsensitiveContains("iPhone") == true)
        #expect(guidance?.localizedCaseInsensitiveContains("App Store") == true)
        #expect(guidance?.localizedCaseInsensitiveContains("TestFlight") == true)
        #expect(MobilePairingFailureCategory.unrecognizedVersion.analyticsReason == "unrecognized_version")
    }

    @Test func incompatibleBuildKeepsUpdateActionInGuidanceOnly() {
        let category = MobilePairingFailureCategory.buildIncompatible
        #expect(!category.message.localizedCaseInsensitiveContains("update cmux"))
        #expect(category.guidance?.localizedCaseInsensitiveContains("update cmux") == true)
    }

    @Test func externalSystemCameraOpenExplainsTheInAppScanBoundary() {
        let category = MobilePairingFailureCategory.externalCodeRequiresInAppScan
        #expect(category.message.localizedCaseInsensitiveContains("outside cmux"))
        #expect(category.guidance?.localizedCaseInsensitiveContains("in-app scanner") == true)
        #expect(!category.guidance!.localizedCaseInsensitiveContains("update cmux"))
    }

    @Test func tokenlessTailscaleURLRequiresExplicitInAppScan() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 58_465)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            authToken: nil
        )
        let policy = MobilePairingURLAuthorizationPolicy()
        #expect(policy.requiresInAppScan(
            ticket: ticket,
            userEnteredPairingCode: false,
            externalURL: true
        ))
        #expect(!policy.requiresInAppScan(
            ticket: ticket,
            userEnteredPairingCode: true,
            externalURL: true
        ))
        #expect(!policy.requiresInAppScan(
            ticket: ticket,
            userEnteredPairingCode: false,
            externalURL: false
        ))

        let legacyTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            authToken: "legacy-attach-token"
        )
        #expect(!policy.requiresInAppScan(
            ticket: legacyTicket,
            userEnteredPairingCode: false,
            externalURL: true
        ))
    }
}

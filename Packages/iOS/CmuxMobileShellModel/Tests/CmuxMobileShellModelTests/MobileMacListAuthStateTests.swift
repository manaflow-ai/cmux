import CmuxMobileShellModel
import Testing

@Suite
@MainActor
struct MobileMacListAuthStateTests {
    @Test
    func comparesReportedVersionToServerFloor() {
        let outdated = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.19+123",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(outdated.isOutdated)

        let current = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20+1",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!current.isOutdated)
    }

    @Test
    func unknownOrMalformedVersionsDoNotWarn() {
        let unknown = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: nil,
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!unknown.isOutdated)

        let malformed = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "nightly",
            minimumSupportedVersion: "0.64.20"
        )
        #expect(!malformed.isOutdated)
    }

    @Test
    func policyFloorOverridesDirectoryFloorAndSurvivesLaterSnapshots() {
        let state = MobileMacListAuthState()
        let entry = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20"
        )
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry],
            minimumSupportedMacVersion: "0.64.20"
        )
        #expect(!state.entry(deviceID: "device")!.isOutdated)

        state.applyPolicyMinimumSupportedMacVersion("0.64.23")
        #expect(state.entry(deviceID: "device")!.isOutdated)
        #expect(state.entry(deviceID: "device")!.minimumSupportedVersion == "0.64.23")

        // A directory refresh without the legacy server floor must not erase
        // the current iOS build's policy floor.
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry]
        )
        #expect(state.entry(deviceID: "device")!.isOutdated)
        #expect(state.minimumSupportedMacVersion == "0.64.23")
    }

    @Test
    func failOpenPolicyClearsExistingWarningWithoutLosingRememberedVersion() {
        let state = MobileMacListAuthState()
        let entry = MobileMacListAuthState.Entry(
            status: "active",
            revoked: false,
            isFresh: true,
            appVersion: "0.64.20",
            minimumSupportedVersion: "0.64.23"
        )
        state.replace(
            entriesByEndpointID: ["endpoint": entry],
            entriesByDeviceID: ["device": entry],
            minimumSupportedMacVersion: "0.64.23"
        )
        #expect(state.entry(deviceID: "device")!.isOutdated)

        state.applyPolicyMinimumSupportedMacVersion(nil)
        #expect(state.entry(deviceID: "device")!.appVersion == "0.64.20")
        #expect(!state.entry(deviceID: "device")!.isOutdated)
    }
}

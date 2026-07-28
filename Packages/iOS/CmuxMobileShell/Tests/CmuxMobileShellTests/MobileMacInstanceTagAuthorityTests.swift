import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacInstanceTagAuthorityTests {
    @Test func storedAuthorityRejectsDifferentTagButPreservesAuthenticatedLegacyHost() {
        let expectation = MobileMacInstanceTagAuthority.expectation(
            storedInstanceTag: "feature-a"
        )
        #expect(expectation == .preserve("feature-a"))
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .reject)
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: expectation,
            reportedInstanceTag: nil
        ) == .accept("feature-a"))
    }

    @Test func legacyAuthorityAdoptsAuthenticatedTag() {
        let expectation = MobileMacInstanceTagAuthority.expectation(storedInstanceTag: nil)
        #expect(expectation == .adopt)
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
    }

    @Test func explicitRegistrySelectionRequiresExactReportedTag() {
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: nil
        ) == .reject)
        #expect(MobileMacInstanceTagAuthority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-a"
        ) == .reject)
    }

    @Test func secondaryStatusRequiresDeviceAndStoredTagWhileLegacyAllowsSameDevice() {
        #expect(MobileMacInstanceTagAuthority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-a"
        ))
        #expect(!MobileMacInstanceTagAuthority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
        #expect(!MobileMacInstanceTagAuthority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-c",
            reportedInstanceTag: "feature-a"
        ))
        #expect(MobileMacInstanceTagAuthority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: nil,
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
    }

    @Test func deviceAuthorityCanonicalizesUUIDsWithoutFoldingOpaqueIDs() {
        #expect(MobileMacInstanceTagAuthority.authenticatedDeviceMatches(
            reportedDeviceID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            expectedDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        ))
        #expect(!MobileMacInstanceTagAuthority.authenticatedDeviceMatches(
            reportedDeviceID: "Legacy-Mac-ID",
            expectedDeviceID: "legacy-mac-id"
        ))
    }

    @Test func registryRefreshRequiresSameDeviceAndInstanceAuthority() {
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-a",
            activeMacInstanceTag: "feature-a",
            targetMacID: "mac-a",
            targetInstanceTag: "feature-a"
        ))
        #expect(!DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-a",
            activeMacInstanceTag: "feature-b",
            targetMacID: "mac-a",
            targetInstanceTag: "feature-a"
        ))
    }
}

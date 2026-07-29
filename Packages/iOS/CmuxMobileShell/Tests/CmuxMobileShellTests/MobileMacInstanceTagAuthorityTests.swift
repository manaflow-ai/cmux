import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacInstanceTagAuthorityTests {
    @Test func storedAuthorityRejectsDifferentTagButPreservesAuthenticatedLegacyHost() {
        let expectation = mobileMacInstanceTagExpectation(
            storedInstanceTag: "feature-a"
        )
        #expect(expectation == .preserve("feature-a"))
        #expect(resolveMobileMacInstanceTag(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .reject)
        #expect(resolveMobileMacInstanceTag(
            expectation: expectation,
            reportedInstanceTag: nil
        ) == .accept("feature-a"))
    }

    @Test func legacyAuthorityAdoptsAuthenticatedTag() {
        let expectation = mobileMacInstanceTagExpectation(storedInstanceTag: nil)
        #expect(expectation == .adopt)
        #expect(resolveMobileMacInstanceTag(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
    }

    @Test func explicitRegistrySelectionRequiresExactReportedTag() {
        #expect(resolveMobileMacInstanceTag(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
        #expect(resolveMobileMacInstanceTag(
            expectation: .require("feature-b"),
            reportedInstanceTag: nil
        ) == .reject)
        #expect(resolveMobileMacInstanceTag(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-a"
        ) == .reject)
    }

    @Test func secondaryStatusRequiresDeviceAndStoredTagWhileLegacyAllowsSameDevice() {
        #expect(mobileSecondaryStatusAuthority(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: nil,
            reportedInstanceTag: nil
        ) == .identityUnavailable)
        #expect(mobileSecondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-a"
        ))
        #expect(!mobileSecondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
        #expect(!mobileSecondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-c",
            reportedInstanceTag: "feature-a"
        ))
        #expect(mobileSecondaryStatusAuthority(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-c",
            reportedInstanceTag: "feature-a"
        ) == .rejected)
        #expect(mobileSecondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: nil,
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
    }

    @Test func deviceAuthorityCanonicalizesUUIDsWithoutFoldingOpaqueIDs() {
        #expect(mobileMacAuthenticatedDeviceMatches(
            reportedDeviceID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            expectedDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        ))
        #expect(!mobileMacAuthenticatedDeviceMatches(
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

import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacInstanceTagAuthorityTests {
    private let authority = MobileMacInstanceTagAuthority()

    @Test func storedAuthorityRejectsDifferentTagButPreservesAuthenticatedLegacyHost() {
        let expectation = authority.expectation(
            storedInstanceTag: "feature-a"
        )
        #expect(expectation == .preserve("feature-a"))
        #expect(authority.resolve(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .reject)
        #expect(authority.resolve(
            expectation: expectation,
            reportedInstanceTag: nil
        ) == .accept("feature-a"))
    }

    @Test func legacyAuthorityAdoptsAuthenticatedTag() {
        let expectation = authority.expectation(storedInstanceTag: nil)
        #expect(expectation == .adopt)
        #expect(authority.resolve(
            expectation: expectation,
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
    }

    @Test func explicitRegistrySelectionRequiresExactReportedTag() {
        #expect(authority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-b"
        ) == .accept("feature-b"))
        #expect(authority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: nil
        ) == .reject)
        #expect(authority.resolve(
            expectation: .require("feature-b"),
            reportedInstanceTag: "feature-a"
        ) == .reject)
    }

    @Test func secondaryStatusRequiresDeviceAndStoredTagWhileLegacyAllowsSameDevice() {
        #expect(authority.secondaryStatusAuthority(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: nil,
            reportedInstanceTag: nil
        ) == .identityUnavailable)
        #expect(authority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-a"
        ))
        #expect(!authority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
        #expect(!authority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-c",
            reportedInstanceTag: "feature-a"
        ))
        #expect(authority.secondaryStatusAuthority(
            expectedDeviceID: "mac-a",
            storedInstanceTag: "feature-a",
            reportedDeviceID: "mac-c",
            reportedInstanceTag: "feature-a"
        ) == .rejected)
        #expect(authority.secondaryStatusMatches(
            expectedDeviceID: "mac-a",
            storedInstanceTag: nil,
            reportedDeviceID: "mac-a",
            reportedInstanceTag: "feature-b"
        ))
    }

    @Test func deviceAuthorityCanonicalizesUUIDsWithoutFoldingOpaqueIDs() {
        #expect(authority.authenticatedDeviceMatches(
            reportedDeviceID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
            expectedDeviceID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        ))
        #expect(!authority.authenticatedDeviceMatches(
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

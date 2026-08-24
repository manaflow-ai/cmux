#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// The three-tier visibility behind the Settings backend section, fed through
/// the REAL switch gate with `CMUXAuthUser` fixtures and keyed on the
/// SELECTION: gate-allowed users and DEBUG builds get the full picker,
/// everyone else whose selection resolves staging (explicit choice or staging
/// LANE alike) gets the recovery-only section, and everyone else on
/// production sees nothing — except mid-switch, where the section must stay
/// mounted.
@Suite
struct MobileBackendEnvironmentSectionVisibilityTests {
    private static let verifiedTeamUser = CMUXAuthUser(
        id: "team",
        primaryEmail: "aziz@manaflow.ai",
        displayName: "Team",
        primaryEmailVerified: true
    )
    private static let unverifiedTeamUser = CMUXAuthUser(
        id: "unverified",
        primaryEmail: "someone@manaflow.ai",
        displayName: "Unverified",
        primaryEmailVerified: false
    )
    private static let outsideUser = CMUXAuthUser(
        id: "outside",
        primaryEmail: "someone@example.com",
        displayName: "Outside",
        primaryEmailVerified: true
    )

    private func resolve(
        user: CMUXAuthUser?,
        isDebugBuild: Bool = false,
        isSwitchRunning: Bool = false,
        selection: CMUXBackendEnvironmentSelection
    ) -> MobileBackendEnvironmentSectionVisibility {
        MobileBackendEnvironmentSectionVisibility.resolve(
            isGateAllowed: CMUXBackendEnvironmentSwitchGate.allows(user),
            isDebugBuild: isDebugBuild,
            isSwitchRunning: isSwitchRunning,
            selection: selection
        )
    }

    @Test
    func verifiedTeamUserGetsTheFullPickerOnAnySelection() {
        #expect(resolve(
            user: Self.verifiedTeamUser,
            selection: .lane(resolves: .production)
        ) == .fullPicker)
        #expect(resolve(
            user: Self.verifiedTeamUser,
            selection: .lane(resolves: .staging)
        ) == .fullPicker)
        #expect(resolve(
            user: Self.verifiedTeamUser,
            selection: .explicit(.staging)
        ) == .fullPicker)
        #expect(resolve(
            user: Self.verifiedTeamUser,
            selection: .explicit(.production)
        ) == .fullPicker)
    }

    @Test
    func debugBuildGetsTheFullPickerWithoutAnyUser() {
        #expect(resolve(
            user: nil,
            isDebugBuild: true,
            selection: .lane(resolves: .production)
        ) == .fullPicker)
        #expect(resolve(
            user: nil,
            isDebugBuild: true,
            selection: .explicit(.staging)
        ) == .fullPicker)
    }

    @Test
    func nonGateUsersOnAStagingResolvedSelectionGetTheRecoverySection() {
        // Unverified team email, verified outside email, and signed out all
        // fail the gate — but a device resolving staging must always show
        // the recovery section, whether the staging comes from an explicit
        // choice or the build's own LANE (the section itself then offers the
        // switch-back button only for the explicit choice).
        #expect(resolve(
            user: Self.unverifiedTeamUser,
            selection: .explicit(.staging)
        ) == .stagingRecovery)
        #expect(resolve(
            user: Self.outsideUser,
            selection: .explicit(.staging)
        ) == .stagingRecovery)
        #expect(resolve(user: nil, selection: .explicit(.staging)) == .stagingRecovery)
        #expect(resolve(user: nil, selection: .lane(resolves: .staging)) == .stagingRecovery)
    }

    @Test
    func nonGateUsersOnProductionResolvedSelectionsSeeNothingWhenIdle() {
        // Production lane, custom lanes (which resolve production), and an
        // explicit production choice all hide the section for non-gate users.
        #expect(resolve(
            user: Self.unverifiedTeamUser,
            selection: .lane(resolves: .production)
        ) == .hidden)
        #expect(resolve(
            user: Self.outsideUser,
            selection: .explicit(.production)
        ) == .hidden)
        #expect(resolve(user: nil, selection: .lane(resolves: .production)) == .hidden)
    }

    @Test
    func runningSwitchKeepsTheSectionMountedAfterParkingDetachesTheUser() {
        // Mid-switch the park detaches `currentUser`, killing the gate
        // clause while the selection still reads production; the running
        // flag must keep the (disabled) picker mounted instead of unmounting
        // the section under the overlay.
        #expect(resolve(
            user: nil,
            isSwitchRunning: true,
            selection: .lane(resolves: .production)
        ) == .fullPicker)
    }

    @Test
    func runningSwitchAwayFromStagingStaysRecovery() {
        // The resolved-staging check wins before the keep-mounted branch, so
        // a non-gate user's switch-back run never flashes into a picker.
        #expect(resolve(
            user: nil,
            isSwitchRunning: true,
            selection: .explicit(.staging)
        ) == .stagingRecovery)
    }
}
#endif

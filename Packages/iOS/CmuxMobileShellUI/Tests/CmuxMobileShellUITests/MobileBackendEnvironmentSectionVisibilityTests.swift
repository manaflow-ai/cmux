#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// The three-tier visibility behind the Settings backend section, fed through
/// the REAL switch gate with `CMUXAuthUser` fixtures: gate-allowed users and
/// DEBUG builds get the full picker, everyone else stranded on staging gets
/// the recovery-only section, and everyone else on production sees nothing —
/// except mid-switch, where the section must stay mounted.
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
        active: CMUXBackendEnvironmentOverride
    ) -> MobileBackendEnvironmentSectionVisibility {
        MobileBackendEnvironmentSectionVisibility.resolve(
            isGateAllowed: CMUXBackendEnvironmentSwitchGate.allows(user),
            isDebugBuild: isDebugBuild,
            isSwitchRunning: isSwitchRunning,
            active: active
        )
    }

    @Test
    func verifiedTeamUserGetsTheFullPickerOnEitherEnvironment() {
        #expect(resolve(user: Self.verifiedTeamUser, active: .production) == .fullPicker)
        #expect(resolve(user: Self.verifiedTeamUser, active: .staging) == .fullPicker)
    }

    @Test
    func debugBuildGetsTheFullPickerWithoutAnyUser() {
        #expect(resolve(user: nil, isDebugBuild: true, active: .production) == .fullPicker)
        #expect(resolve(user: nil, isDebugBuild: true, active: .staging) == .fullPicker)
    }

    @Test
    func nonGateUsersOnStagingGetTheRecoverySection() {
        // Unverified team email, verified outside email, and signed out all
        // fail the gate — but a staging device must always offer the way
        // back to production.
        #expect(resolve(user: Self.unverifiedTeamUser, active: .staging) == .stagingRecovery)
        #expect(resolve(user: Self.outsideUser, active: .staging) == .stagingRecovery)
        #expect(resolve(user: nil, active: .staging) == .stagingRecovery)
    }

    @Test
    func nonGateUsersOnProductionSeeNothingWhenIdle() {
        #expect(resolve(user: Self.unverifiedTeamUser, active: .production) == .hidden)
        #expect(resolve(user: Self.outsideUser, active: .production) == .hidden)
        #expect(resolve(user: nil, active: .production) == .hidden)
    }

    @Test
    func runningSwitchKeepsTheSectionMountedAfterParkingDetachesTheUser() {
        // Mid-switch the park detaches `currentUser`, killing the gate
        // clause while active still reads production; the running flag must
        // keep the (disabled) picker mounted instead of unmounting the
        // section under the overlay.
        #expect(resolve(
            user: nil,
            isSwitchRunning: true,
            active: .production
        ) == .fullPicker)
    }

    @Test
    func runningSwitchAwayFromStagingStaysRecovery() {
        // The active check wins before the keep-mounted branch, so a
        // non-gate user's switch-back run never flashes into a picker.
        #expect(resolve(
            user: nil,
            isSwitchRunning: true,
            active: .staging
        ) == .stagingRecovery)
    }
}
#endif

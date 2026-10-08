import Testing
@testable import CmuxSettingsUI

@Suite("Pro upgrade card")
struct ProUpgradeCardTests {
    @Test("plan refresh reruns when session restoration finishes")
    func planRefreshKeyTracksAuthReadiness() {
        let restoring = AccountPlanRefreshKey(
            accountID: "account-1",
            isAuthenticated: false,
            isWorkingOnAuth: true,
            selectedTeamID: nil
        )
        let ready = AccountPlanRefreshKey(
            accountID: "account-1",
            isAuthenticated: true,
            isWorkingOnAuth: false,
            selectedTeamID: nil
        )

        #expect(restoring != ready)
    }
}

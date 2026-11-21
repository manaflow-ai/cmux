import CmuxNextAccounts
import CmuxNextCodeRouter
import CmuxNextSettings
import Testing

/// `cmux accounts list` reads the rows through `controlList`: on a Mac where
/// Settings > Accounts never opened, nothing else starts detection, and the
/// list reported every provider Checking… forever (a NIGHTLY,
/// 2026-11-21, 2.5 h after launch).
@MainActor
@Suite struct AccountsListDetectsTests {
    @Test func aModelNobodyRefreshedStartsDetectingAndNeverStaysChecking() async {
        let model = AccountsModel(services: MockAccountsServices())
        #expect(model.rows.allSatisfy { $0.phase == .detecting })

        let list = await model.controlList(activeTeam: .null, handlesStable: true)

        #expect(list["refreshing"] == .bool(false))
        let phases = (list["providers"]?.arrayValue ?? []).compactMap { $0["phase"]?.stringValue }
        #expect(phases.count == model.rows.count)
        #expect(!phases.contains("detecting"))
    }
}

@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextFocus
import CmuxNextSettings
import Testing

/// The app's half of opt-in usage recording: every shown focus folds to its surface through its
/// stable name (`FocusState.Resolved.kind`, what the app hands ``UsageRecorder``), and the sheet
/// that approves turning it on from the CLI shows what the record holds.
@MainActor @Suite struct UsageRecordingTests {
    @Test(arguments: [
        (FocusState.Resolved.terminal(pane: "p", tab: "t"), UsageSurface.terminal),
        (.browserPage(pane: "p", tab: "t"), .browser),
        (.addressBar(pane: "p", tab: "t"), .browser),
        (.findBar(pane: "p", tab: "t"), .browser),
        (.devTools(pane: "p", tab: "t"), .browser),
        (.agentPage(pane: "p", tab: "t"), .chat),
        (.page(pane: "p", tab: "t"), .page),
        (.conversation(pane: "p", tab: "t"), .conversation),
        (.sidebar, .sidebar),
        (.sidebarField, .sidebar),
        (.overlay(.palette), .palette),
        (.overlay(.sheet), .overlay),
        (.overlay(.rename), .overlay),
        (.overlay(.groupEditor), .overlay),
        (.emptyPane(pane: "p"), .other),
        (.textField, .other),
        (.none, .other),
    ])
    func eachShownFocusFoldsToItsSurface(resolved: FocusState.Resolved, surface: UsageSurface) {
        #expect(UsageSurface(kind: resolved.kind) == surface)
    }

    @Test func theConfirmationSheetForTurningItOnShowsWhatTheRecordHolds() {
        #expect(UserOnlySettingConfirmation.body(key: "diagnostics.usageRecording", value: .bool(true)).contains(UsageRecorder.privacySummary))
        #expect(!UserOnlySettingConfirmation.body(key: "diagnostics.usageRecording", value: .bool(false)).contains(UsageRecorder.privacySummary))
        #expect(!UserOnlySettingConfirmation.body(key: "diagnostics.hangReports", value: .bool(true)).contains(UsageRecorder.privacySummary))
    }

    @Test func theConfirmationSheetForSharingShowsWhatGoesToTheTeam() {
        #expect(UserOnlySettingConfirmation.body(key: "diagnostics.usageSharing", value: .bool(true)).contains(UsageSharing.privacySummary))
        #expect(!UserOnlySettingConfirmation.body(key: "diagnostics.usageSharing", value: .bool(false)).contains(UsageSharing.privacySummary))
        #expect(!UserOnlySettingConfirmation.body(key: "diagnostics.usageRecording", value: .bool(true)).contains(UsageSharing.privacySummary))
    }
}

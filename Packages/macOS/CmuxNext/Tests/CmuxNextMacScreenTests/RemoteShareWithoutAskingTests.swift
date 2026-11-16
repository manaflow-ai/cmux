import CmuxNextActions
@testable import CmuxNextMacScreen
import CmuxNextSettings
import Testing

/// `cmux remote-host share on` showed the "Share This Mac" sheet on every call, even when this Mac
/// already shared, with no way to say yes for good (Leo, 2026-11-16: "i dont want to have to click
/// share this mac allow every single time when screen sharing"). The sheet now offers Always Allow,
/// which turns on the user-only `remote.shareWithoutAsking`; an agent cannot turn it on itself.
@MainActor
@Suite struct RemoteShareWithoutAskingTests {
    @Test func asksOnlyWhenSharingWouldChangeAndThePersonHasNotSaidAlways() {
        typealias Env = CmuxRemoteActionEnvironment
        #expect(Env.shareStep(alreadyShared: false, withoutAsking: false) == .ask)
        #expect(Env.shareStep(alreadyShared: false, withoutAsking: true) == .apply)
        // Already sharing: no dialog and no write, so a hub list that is behind cannot turn sharing back on.
        #expect(Env.shareStep(alreadyShared: true, withoutAsking: false) == .nothing)
        #expect(Env.shareStep(alreadyShared: true, withoutAsking: true) == .nothing)
    }

    @Test func theShareRequestsSheetOffersAlwaysAllowAndTheShareButtonsSheetDoesNot() {
        let request = CmuxRemoteSharingSetup.spec(.overview, offerAlways: true).buttons
        #expect(request.map(\.id) == ["cancel", "always", "continue"])
        #expect(request.last?.role == .default)
        #expect(CmuxRemoteSharingSetup.spec(.overview).buttons.map(\.id) == ["cancel", "continue"])
    }

    @Test func theSettingIsOffByDefaultAndOnlyThePersonTurnsItOn() throws {
        #expect(RemoteSettings().shareWithoutAsking == false)
        let descriptor = try #require(SettingsSchema.descriptor(for: RemoteSettings.shareWithoutAskingPath))
        #expect(SettingWriter.user.mayWrite(descriptor))
        for origin: SettingWriter in [SettingWriter(.cli), SettingWriter(.mcp), SettingWriter(.script), SettingWriter(.remote)] {
            #expect(!origin.mayWrite(descriptor))
        }
    }
}

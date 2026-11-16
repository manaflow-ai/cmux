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

    /// Already shared (`.nothing`): no hub write, but a missing Screen Recording grant still gets its
    /// step, as the request did before the sheet (#44072 review at 53282b4: it returned at once).
    @Test func alreadySharedStillAsksForAMissingGrantWithoutWritingTheHub() async throws {
        let setup = RemoteShareGrantTests.Setup()
        setup.permissions = (false, true)
        setup.answers = ["cancel"]
        let declined = try await CmuxRemoteActionEnvironment.shareWithoutOverview(.nothing, setup: setup.make()) { setup.present($0) }
        #expect(!declined)
        #expect(setup.presented == ["cmux.dialog.screenSharing.setup.screen"])
        #expect(setup.enables == 0)

        setup.presented = []
        setup.permissions = (true, true)
        let granted = try await CmuxRemoteActionEnvironment.shareWithoutOverview(.nothing, setup: setup.make()) { setup.present($0) }
        #expect(granted)
        #expect(setup.presented.isEmpty)
        #expect(setup.enables == 0)
    }

    /// Always Allow (`.apply`): no overview; sharing goes on once the grants are there.
    @Test func alwaysAllowSharesWithNoOverview() async throws {
        let setup = RemoteShareGrantTests.Setup()
        let shared = try await CmuxRemoteActionEnvironment.shareWithoutOverview(.apply, setup: setup.make()) { setup.present($0) }
        #expect(shared)
        #expect(setup.presented.isEmpty)
        #expect(setup.enables == 1)
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

import Testing
@testable import CmuxNextRemoteView

/// The app never asks macOS for Screen Recording (the Screen Sharing helper holds every screen
/// grant): sharing this Mac's screen upstream is refused without a prompt.
@MainActor struct RemoteUpstreamPermissionsTests {
    @Test func aScreenShareNeverPromptsForTheApp() async {
        #expect(await SystemUpstreamPermissions().request(.screen) == false)
    }
}

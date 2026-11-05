import Testing
@testable import CmuxNextDaemon

/// Switch Account keeps Cloud signed in with another person: the session
/// begins again for the new user, and the app learns that the previous
/// account's link ended, so it drops that account's machines too.
@MainActor
struct CloudLinkLifecycleAccountSwitchTests {
    @Test func aSessionForAnotherUserSaysThePreviousOneEnded() async {
        let lifecycle = CloudLinkLifecycle(launcher: nil, installID: { nil }, connection: { nil })
        #expect(await lifecycle.sessionBegan(user: "user-a") == false)
        #expect(await lifecycle.sessionBegan(user: "user-a") == false)
        #expect(await lifecycle.sessionBegan(user: "user-b") == true)
    }

    @Test func aTeamSwitchEndsThePreviousLinkForTheSameUser() async {
        let launcher = RecordingLauncher()
        let lifecycle = CloudLinkLifecycle(launcher: launcher, installID: { "install" }, connection: { nil })
        lifecycle.isAvailable = { true }
        lifecycle.isSignedIn = { true }
        #expect(await lifecycle.sessionBegan(user: "user", team: "team-a") == false)
        await lifecycle.ensureLink()
        #expect(await lifecycle.sessionBegan(user: "user", team: "team-b") == true)
        #expect(launcher.ensureCount == 1)
        #expect(launcher.stopCount == 1)
        #expect(launcher.archiveCount == 1)
    }

    @MainActor
    private final class RecordingLauncher: CloudLinkLaunching {
        var ensureCount = 0
        var stopCount = 0
        var archiveCount = 0

        func ensure(install: String) async throws -> CloudLinkLauncher.Ensured {
            ensureCount += 1
            return .init(status: "started", pid: 7, socket: "/tmp/native-link.sock")
        }

        func stop(install: String?) async { stopCount += 1 }
        func archive(install: String?) async { archiveCount += 1 }
    }
}

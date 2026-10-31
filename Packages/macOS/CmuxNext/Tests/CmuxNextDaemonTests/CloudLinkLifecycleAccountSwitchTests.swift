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
}

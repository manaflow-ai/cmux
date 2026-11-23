import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

@MainActor
struct HostBrowserSignOutTests {
    @Test func signOutDuringCallbackValidationStillRevokesWithCapturedCredentials() async {
        // If callback validation resumes inside credential capture, the flow
        // must leave local clearing to the coordinator so teardown retains the
        // exact signed-out credentials.
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user, clock: clock)
        await harness.client.closeUserGate()

        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        await clock.waitUntilSleepers(count: 3)
        harness.factory.sessions[0].deliver(harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0])))
        await harness.waitForPendingUserRequest()

        await harness.client.armStoredAccessTokenGate()
        let signOut = Task { await harness.flow.signOut() }
        await harness.client.storedAccessTokenDidPark()

        await harness.client.openUserGate()
        clock.advance(by: .seconds(60))
        #expect(await attempt.value == false)

        await harness.client.releaseStoredAccessTokenGate()
        await signOut.value

        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
        let revoked = await harness.client.revokedCredentials
        #expect(revoked.count == 1)
        #expect(revoked.first?.access == "access-1")
        #expect(revoked.first?.refresh == "refresh-1")
    }
}

actor HostBrowserSignOutHookRecorder {
    typealias Call = (accessToken: String?, refreshToken: String?)
    private var calls: [Call] = []

    func record(_ accessToken: String?, _ refreshToken: String?) {
        calls.append((accessToken, refreshToken))
    }

    func values() -> [Call] {
        calls
    }
}

@MainActor
final class HostBrowserSignOutOrderingRecorder {
    enum Event: Equatable, Sendable {
        case prepare
        case signedOut
    }

    private var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }

    func values() -> [Event] {
        events
    }
}

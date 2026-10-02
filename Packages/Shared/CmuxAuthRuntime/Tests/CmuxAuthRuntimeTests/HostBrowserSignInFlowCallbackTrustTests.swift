import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Which token-bearing callbacks the hosted-browser flow is willing to apply.
/// A callback is applied only for an app-issued, unexpired, single-use state,
/// a trusted embedded-browser handoff, or an explicit user approval.
@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowCallbackTrustTests {
    @Test func unsolicitedStatelessCallbackIsNotAppliedWithoutApproval() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let result = await harness.flow.handleCallbackURL(harness.fallbackCallbackURL())

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(await harness.tokenStore.getStoredAccessToken() == nil)
    }

    @Test func unsolicitedStatelessCallbackDoesNotReplaceSignedInSession() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        session.deliver(URL(string: "cmux-dev://auth-callback?stack_refresh=victim-r&stack_access=victim-a&cmux_auth_state=\(harness.callbackState(session))")!)
        #expect(await attempt.value)

        let result = await harness.flow.handleCallbackURL(harness.fallbackCallbackURL())

        #expect(result == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "victim-r")
        #expect(await harness.tokenStore.getStoredAccessToken() == "victim-a")
    }

    @Test func expiredIssuedStateIsRejected() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user, browserAttemptTimeout: 60, clock: clock)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let state = try #require(Self.state(in: fallbackURL))
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        clock.advance(by: .seconds(61))
        let result = await harness.flow.handleCallbackURL(harness.callbackURL(state: state))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func expiredManualStateIsRejected() async throws {
        let clock = ManualTestClock()
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user, browserAttemptTimeout: 60, clock: clock)

        let manualURL = harness.flow.manualSignInURL
        let state = try #require(Self.state(in: manualURL))
        let attempt = Task { await harness.flow.signIn(timeout: 600) }
        await harness.waitForSession()
        harness.factory.sessions[0].cancel()
        #expect(await attempt.value == false)

        clock.advance(by: .seconds(61))
        let result = await harness.flow.handleCallbackURL(harness.callbackURL(state: state))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func issuedStateIsSingleUse() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let state = try #require(Self.state(in: fallbackURL))
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: state)))

        let replay = URL(string: "cmux-dev://auth-callback?stack_refresh=attacker-r&stack_access=attacker-a&cmux_auth_state=\(state)")!
        #expect(await harness.flow.handleCallbackURL(replay) == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await harness.tokenStore.getStoredAccessToken() == "access-1")
    }

    @Test func mismatchedStateWithoutActiveAttemptIsRejected() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)
        _ = harness.flow.manualSignInURL

        let result = await harness.flow.handleCallbackURL(harness.callbackURL(state: "attacker-state"))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    static func state(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value
    }
}

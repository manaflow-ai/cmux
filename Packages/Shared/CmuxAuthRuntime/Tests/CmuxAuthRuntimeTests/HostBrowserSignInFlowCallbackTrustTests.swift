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

    @Test func approvedUnsolicitedCallbackSignsInOnce() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let recorder = ApprovalRecorder(answer: true)
        let harness = HostBrowserSignInFlowHarness(user: user, approveUnsolicitedCallback: recorder.approve)

        let result = await harness.flow.handleCallbackURL(Self.statelessURL(email: "new@example.com"))

        #expect(result)
        #expect(harness.coordinator.isAuthenticated)
        #expect(recorder.requests == [UnsolicitedAuthCallbackApprovalRequest(
            accountEmail: "new@example.com",
            currentAccountEmail: nil,
            replacesSignedInSession: false
        )])
    }

    @Test func declinedUnsolicitedCallbackIsNotApplied() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let recorder = ApprovalRecorder(answer: false)
        let harness = HostBrowserSignInFlowHarness(user: user, approveUnsolicitedCallback: recorder.approve)

        let result = await harness.flow.handleCallbackURL(harness.fallbackCallbackURL())

        #expect(result == false)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.accountEmail == nil)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func unsolicitedCallbackWhileSignedInFlagsReplacement() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let recorder = ApprovalRecorder(answer: false)
        let harness = HostBrowserSignInFlowHarness(user: user, approveUnsolicitedCallback: recorder.approve)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        session.deliver(URL(string: "cmux-dev://auth-callback?stack_refresh=victim-r&stack_access=victim-a&cmux_auth_state=\(harness.callbackState(session))")!)
        #expect(await attempt.value)

        let result = await harness.flow.handleCallbackURL(Self.statelessURL(email: "attacker@example.com"))

        #expect(result == false)
        #expect(recorder.requests == [UnsolicitedAuthCallbackApprovalRequest(
            accountEmail: "attacker@example.com",
            currentAccountEmail: "a@b.com",
            replacesSignedInSession: true
        )])
        #expect(await harness.tokenStore.getStoredRefreshToken() == "victim-r")
    }

    @Test func trustedEmbeddedStatelessCallbackSignsInWithoutPrompt() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let recorder = ApprovalRecorder(answer: false)
        let harness = HostBrowserSignInFlowHarness(user: user, approveUnsolicitedCallback: recorder.approve)

        let result = await harness.flow.handleCallbackURL(harness.fallbackCallbackURL(), delivery: .trustedEmbeddedBrowser)

        #expect(result)
        #expect(recorder.requests.isEmpty)
        #expect(harness.coordinator.isAuthenticated)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func trustedEmbeddedDeliveryStillRequiresIssuedState() async {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let harness = HostBrowserSignInFlowHarness(user: user)

        let result = await harness.flow.handleCallbackURL(
            harness.callbackURL(state: "attacker-state"),
            delivery: .trustedEmbeddedBrowser
        )

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
    }

    @Test func validIssuedStateAppliesWithoutPrompt() async throws {
        let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")
        let recorder = ApprovalRecorder(answer: false)
        let harness = HostBrowserSignInFlowHarness(user: user, approveUnsolicitedCallback: recorder.approve)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let state = try #require(Self.state(in: fallbackURL))
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: state)))
        #expect(recorder.requests.isEmpty)
        #expect(harness.coordinator.isAuthenticated)
    }

    @Test func constantTimeEqualsComparesWholeValues() {
        #expect(HostBrowserIssuedCallbackStates.constantTimeEquals("abc", "abc"))
        #expect(!HostBrowserIssuedCallbackStates.constantTimeEquals("abc", "abd"))
        #expect(!HostBrowserIssuedCallbackStates.constantTimeEquals("abc", "abcd"))
        #expect(!HostBrowserIssuedCallbackStates.constantTimeEquals("", "a"))
        #expect(!HostBrowserIssuedCallbackStates.constantTimeEquals(nil, nil))
        #expect(!HostBrowserIssuedCallbackStates.constantTimeEquals("abc", nil))
    }

    /// A stateless callback whose access token is a JWT claiming `email`.
    static func statelessURL(email: String) -> URL {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let jwt = "\(segment(["alg": "none"])).\(segment(["sub": "x", "email": email])).sig"
        return URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=\(jwt)")!
    }

    static func state(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value
    }
}

@MainActor
final class ApprovalRecorder {
    private(set) var requests: [UnsolicitedAuthCallbackApprovalRequest] = []
    private let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    var approve: @MainActor (UnsolicitedAuthCallbackApprovalRequest) async -> Bool {
        { [self] request in
            requests.append(request)
            return answer
        }
    }
}

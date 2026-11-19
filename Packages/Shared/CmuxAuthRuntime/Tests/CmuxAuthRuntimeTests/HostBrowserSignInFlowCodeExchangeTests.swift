import CMUXAuthCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records each redemption and answers like `POST /api/native/token`: tokens
/// only when the verifier hashes to the challenge the sign-in URL carried.
actor FakeCodeRedeemer: AuthCallbackCodeRedeeming {
    private(set) var redemptions: [(code: String, verifier: String)] = []
    private var challenge: String?
    private let failure: AuthError?

    init(failure: AuthError? = nil) {
        self.failure = failure
    }

    func expect(challenge: String?) {
        self.challenge = challenge
    }

    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        redemptions.append((code, verifier))
        if let failure { throw failure }
        guard let challenge, HostBrowserPKCE(verifier: verifier).challenge == challenge else {
            throw AuthError.invalidCallback
        }
        return AuthCallbackPayload(refreshToken: "redeemed-refresh", accessToken: "redeemed-access")
    }
}

@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowCodeExchangeTests {
    private static let code = String(repeating: "C", count: 43)
    private let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")

    private static func query(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func codeCallback(state: String?, code: String = code) -> URL {
        let stateItem = state.map { "&cmux_auth_state=\($0)" } ?? ""
        return URL(string: "cmux-dev://auth-callback?code=\(code)\(stateItem)")!
    }

    @Test func signInURLCarriesAnS256ChallengeAndNeverTheVerifier() async throws {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let url = harness.factory.sessions[0].signInURL

        let challenge = try #require(Self.query("code_challenge", in: url))
        #expect(Self.query("code_challenge_method", in: url) == "S256")
        #expect(challenge.count == 43)
        #expect(challenge.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(Self.query("code_verifier", in: url) == nil)
        // The state the app already sent is still there, untouched.
        #expect(!harness.callbackState(harness.factory.sessions[0]).isEmpty)
        harness.flow.cancelSignIn()
    }

    @Test func eachAttemptGetsItsOwnChallenge() async throws {
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: FakeCodeRedeemer())

        harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.flow.beginSignIn(selectAccount: true)
        await harness.waitForSession(count: 2)

        let first = try #require(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL))
        let second = try #require(Self.query("code_challenge", in: harness.factory.sessions[1].signInURL))
        #expect(first != second)
        harness.flow.cancelSignIn()
    }

    @Test func codeCallbackForTheLiveAttemptRedeemsWithTheMatchingVerifier() async throws {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        await redeemer.expect(challenge: Self.query("code_challenge", in: session.signInURL))

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(harness.coordinator.isAuthenticated)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "redeemed-refresh")
        let redemptions = await redeemer.redemptions
        #expect(redemptions.count == 1)
        #expect(redemptions.first?.code == Self.code)
        #expect(redemptions.first?.verifier.count == 43)
    }

    @Test func externalCodeCallbackWithAnotherStateIsRejectedWithoutRedeeming() async {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        harness.flow.beginSignIn()
        await harness.waitForSession()

        let result = await harness.flow.handleCallbackURL(Self.codeCallback(state: "someone-elses-state"))

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await redeemer.redemptions.isEmpty)
        harness.flow.cancelSignIn()
    }

    @Test func statelessCodeCallbackIsNeverRedeemed() async {
        let redeemer = FakeCodeRedeemer()
        let approvals = OpenedURLRecorder()
        let harness = HostBrowserSignInFlowHarness(
            user: user,
            approveUnsolicitedCallback: { _ in approvals.append(URL(string: "about:asked")!) },
            codeRedeemer: redeemer
        )

        let result = await harness.flow.handleCallbackURL(Self.codeCallback(state: nil))

        #expect(result == false)
        #expect(approvals.urls.isEmpty)
        #expect(await redeemer.redemptions.isEmpty)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func malformedCodeIsRejectedWithoutRedeeming() async {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session), code: "short"))

        #expect(await attempt.value == false)
        #expect(await redeemer.redemptions.isEmpty)
        #expect(harness.flow.lastFailure == .invalidCallback)
    }

    @Test func failedRedemptionLeavesTheAppSignedOut() async {
        let redeemer = FakeCodeRedeemer(failure: .invalidCallback)
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(harness.flow.lastFailure == .invalidCallback)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func issuedStateRedeemsOnceAfterThePopupEnds() async throws {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        harness.flow.beginSignIn()
        await harness.waitForSession()
        let fallbackURL = try #require(harness.flow.activeAttemptSignInURL)
        let state = try #require(Self.query("cmux_auth_state", in: fallbackURL))
        await redeemer.expect(challenge: Self.query("code_challenge", in: fallbackURL))
        harness.factory.sessions[0].cancel()
        await harness.waitForCondition { harness.flow.isSigningIn == false }

        #expect(await harness.flow.handleCallbackURL(Self.codeCallback(state: state)))
        await harness.flow.signOut()
        #expect(await harness.flow.handleCallbackURL(Self.codeCallback(state: state)) == false)
        #expect(await redeemer.redemptions.count == 1)
    }

    @Test func legacyTokenCallbackStillSignsInDuringTheTransition() async {
        // A cmux.com that predates PKCE ignores the challenge and returns tokens.
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await redeemer.redemptions.isEmpty)
    }

    @Test func withoutARedeemerTheSignInURLIsUnchanged() async {
        let harness = HostBrowserSignInFlowHarness(user: user)
        harness.flow.beginSignIn()
        await harness.waitForSession()

        #expect(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL) == nil)
        harness.flow.cancelSignIn()
    }
}

/// The HTTPS redemption request and its answers.
@Suite struct NativeSignInCodeRedeemerTests {
    private final class Captured: @unchecked Sendable {
        var request: URLRequest?
    }

    private static func redeemer(status: Int, body: String, captured: Captured = Captured()) -> NativeSignInCodeRedeemer {
        NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://cmux.test")!, scheme: "cmux-next") { request in
            captured.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    @Test func postsCodeVerifierAndSchemeAsJSONAndReadsTokensFromTheBody() async throws {
        let captured = Captured()
        let redeemer = Self.redeemer(status: 200, body: #"{"refresh_token":"r","access_token":"a"}"#, captured: captured)

        let payload = try await redeemer.redeem(code: "the-code", verifier: "the-verifier")

        #expect(payload == AuthCallbackPayload(refreshToken: "r", accessToken: "a"))
        let request = try #require(captured.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://cmux.test/api/native/token")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["code": "the-code", "code_verifier": "the-verifier", "scheme": "cmux-next"])
    }

    @Test func refusalsMapToDisplaySafeErrors() async {
        await #expect(throws: AuthError.invalidCallback) {
            try await Self.redeemer(status: 400, body: #"{"error":"invalid_grant"}"#).redeem(code: "c", verifier: "v")
        }
        await #expect(throws: AuthError.rateLimited) {
            try await Self.redeemer(status: 429, body: "").redeem(code: "c", verifier: "v")
        }
        await #expect(throws: AuthError.serverError(503, "code_redeem_failed")) {
            try await Self.redeemer(status: 503, body: "").redeem(code: "c", verifier: "v")
        }
        await #expect(throws: AuthError.serverError(200, "code_redeem_malformed")) {
            try await Self.redeemer(status: 200, body: #"{"refresh_token":""}"#).redeem(code: "c", verifier: "v")
        }
    }

    @Test func transportFailureIsANetworkError() async {
        let redeemer = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://cmux.test")!, scheme: "cmux") { _ in
            throw URLError(.timedOut)
        }
        await #expect(throws: AuthError.networkError) {
            try await redeemer.redeem(code: "c", verifier: "v")
        }
    }
}

@Suite struct HostBrowserPKCETests {
    @Test func s256MatchesRFC7636AppendixB() {
        let pkce = HostBrowserPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifiersAre43RandomBase64URLCharacters() throws {
        let first = try #require(HostBrowserPKCE.make())
        let second = try #require(HostBrowserPKCE.make())
        #expect(first.verifier.count == 43)
        #expect(first.verifier != second.verifier)
        #expect(first.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func callbackCodeAcceptsOnlyAWellFormedCode() {
        let router = AuthCallbackRouter()
        let good = String(repeating: "a", count: 43)
        #expect(router.callbackCode(from: URL(string: "cmux://auth-callback?code=\(good)")!) == good)
        #expect(router.callbackCode(from: URL(string: "cmux://auth-callback?code=short")!) == nil)
        #expect(router.callbackCode(from: URL(string: "cmux://auth-callback?code=\(good)a")!) == nil)
        #expect(router.callbackCode(from: URL(string: "evil://auth-callback?code=\(good)")!) == nil)
        #expect(router.callbackCode(from: URL(string: "cmux://other?code=\(good)")!) == nil)
    }
}

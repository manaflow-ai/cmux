import CMUXAuthCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records each redemption and answers like `POST /api/native/token`: tokens
/// only when the verifier hashes to the challenge the sign-in URL carried.
actor FakeCodeRedeemer: AuthCallbackCodeRedeeming {
    private(set) var redemptions: [(code: String, verifier: String)] = []
    private(set) var capabilityChecks = 0
    private var challenge: String?
    private let failure: AuthError?
    /// What the server's `GET /api/native/token` says, check by check; the last answer repeats.
    private var capabilityAnswers: [CodeExchangeCapability]

    init(failure: AuthError? = nil, capability: [CodeExchangeCapability] = [.supported]) {
        self.failure = failure
        capabilityAnswers = capability
    }

    func expect(challenge: String?) {
        self.challenge = challenge
    }

    nonisolated var signInOrigin: String { "https://example.test" }

    func codeExchangeCapability() async -> CodeExchangeCapability {
        capabilityChecks += 1
        let answer = capabilityAnswers.first ?? .unknown
        if capabilityAnswers.count > 1 { capabilityAnswers.removeFirst() }
        return answer
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

/// Answers 429 once, then tokens.
actor FlakyCodeRedeemer: AuthCallbackCodeRedeeming {
    private(set) var verifiers: [String] = []

    nonisolated var signInOrigin: String { "https://example.test" }
    func codeExchangeCapability() async -> CodeExchangeCapability { .supported }

    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        verifiers.append(verifier)
        if verifiers.count == 1 { throw AuthError.rateLimited }
        return AuthCallbackPayload(refreshToken: "redeemed-refresh", accessToken: "redeemed-access")
    }
}

/// Parks each redemption like a request still in flight, until its task is cancelled.
actor HangingCodeRedeemer: AuthCallbackCodeRedeeming {
    private(set) var wasCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var parked: AsyncStream<Void>.Continuation?

    nonisolated var signInOrigin: String { "https://example.test" }
    func codeExchangeCapability() async -> CodeExchangeCapability { .supported }

    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        // A stream that never yields (its continuation is kept) ends its loop
        // only when the task is cancelled.
        let (never, continuation) = AsyncStream<Void>.makeStream()
        parked = continuation
        for await _ in never {}
        parked = nil
        wasCancelled = Task.isCancelled
        throw CancellationError()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

/// Fails every redemption with a transient error, optionally after moving `clock` on.
actor AlwaysTransientCodeRedeemer: AuthCallbackCodeRedeeming {
    private(set) var redemptions = 0
    private let clock: ManualTestClock
    private let elapsedPerRequest: Duration

    init(clock: ManualTestClock, elapsedPerRequest: Duration = .zero) {
        self.clock = clock
        self.elapsedPerRequest = elapsedPerRequest
    }

    nonisolated var signInOrigin: String { "https://example.test" }
    func codeExchangeCapability() async -> CodeExchangeCapability { .supported }

    func redeem(code: String, verifier: String) async throws -> AuthCallbackPayload {
        redemptions += 1
        if elapsedPerRequest > .zero { clock.advance(by: elapsedPerRequest) }
        throw AuthError.networkError
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
        // The same state again, with no sign-out in between: consumed, never redeemed twice.
        #expect(await harness.flow.handleCallbackURL(Self.codeCallback(state: state)) == false)
        #expect(await redeemer.redemptions.count == 1)
    }

    @Test func tokenPairPresentedWithAPKCEStateIsRejected() async {
        // An app that caught the code callback cannot swap in its own tokens.
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        let result = await harness.flow.handleCallbackURL(
            URL(string: "cmux-dev://auth-callback?stack_refresh=planted-r&stack_access=planted-a&cmux_auth_state=\(harness.callbackState(session))")!
        )

        #expect(result == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        #expect(harness.flow.lastFailure == .invalidCallback)
        harness.flow.cancelSignIn()
        _ = await attempt.value
    }

    @Test func approvedStatelessTokenCallbackStillWorks() async {
        // Purchase returns carry no state and stay behind the user's approval.
        let harness = HostBrowserSignInFlowHarness(
            user: user,
            approveUnsolicitedCallback: { _ in true },
            codeRedeemer: FakeCodeRedeemer()
        )

        #expect(await harness.flow.handleCallbackURL(harness.fallbackCallbackURL()))
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
    }

    @Test func transientRedemptionFailureIsRetriedWithTheSameVerifier() async {
        let redeemer = FlakyCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value)
        let verifiers = await redeemer.verifiers
        #expect(verifiers.count == 2)
        #expect(Set(verifiers).count == 1)
    }

    // MARK: Server capability

    @Test func anOriginWithoutTheCodeRouteKeepsTheTokenHandOff() async {
        let redeemer = FakeCodeRedeemer(capability: [.unsupported])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        #expect(Self.query("code_challenge", in: session.signInURL) == nil)
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        #expect(await redeemer.redemptions.isEmpty)
        #expect(await redeemer.capabilityChecks == 1)
    }

    @Test func aTokenStateRefusesACode() async {
        // The callback never picks the mode: a state sent without a challenge
        // takes only the token pair.
        let redeemer = FakeCodeRedeemer(capability: [.unsupported])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value == false)
        #expect(await redeemer.redemptions.isEmpty)
        #expect(harness.flow.lastFailure == .invalidCallback)
    }

    @Test func onceTheOriginOffersTheCodeItIsNeverDowngraded() async throws {
        // The second check would say no; it is never asked, and the next attempt still sends a challenge.
        let redeemer = FakeCodeRedeemer(capability: [.supported, .unsupported])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.flow.cancelSignIn()
        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)

        #expect(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL) != nil)
        #expect(Self.query("code_challenge", in: harness.factory.sessions[1].signInURL) != nil)
        #expect(await redeemer.capabilityChecks == 1)
        // A token pair for the code attempt is still refused.
        let tokens = harness.callbackURL(state: harness.callbackState(harness.factory.sessions[1]))
        #expect(await harness.flow.handleCallbackURL(tokens) == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
        harness.flow.cancelSignIn()
    }

    enum UnreachableOrigin: String, CaseIterable, Sendable {
        case timeout, serverError, redirect
    }

    /// Counts capability requests through the real redeemer.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test(arguments: UnreachableOrigin.allCases)
    func anOriginWithoutADefinitiveAnswerFailsTheAttemptAndOpensNothing(origin: UnreachableOrigin) async {
        let requests = RequestCounter()
        let redeemer = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://example.test")!, scheme: "cmux-dev") { request in
            requests.increment()
            switch origin {
            case .timeout:
                throw URLError(.timedOut)
            case .serverError:
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            case .redirect:
                let portal = URL(string: "https://portal.example/login")!
                return (Data("Not Found".utf8), HTTPURLResponse(url: portal, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        let signedIn = await harness.flow.signIn(timeout: 60)

        #expect(signedIn == false)
        #expect(harness.factory.sessions.isEmpty)
        #expect(harness.openedURLs.isEmpty)
        #expect(harness.flow.lastFailure == .networkError)
        #expect(harness.flow.isSigningIn == false)
        // Asked once, retried once, never read as "tokens".
        #expect(requests.count == 2)
    }

    @Test func oneUnknownAnswerIsRetriedBeforeDeciding() async throws {
        let redeemer = FakeCodeRedeemer(capability: [.unknown, .supported])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        harness.flow.beginSignIn()
        await harness.waitForSession()

        #expect(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL) != nil)
        #expect(await redeemer.capabilityChecks == 2)
        harness.flow.cancelSignIn()
    }

    @Test func aDefinitive404PicksTheTokenHandOff() async {
        let redeemer = FakeCodeRedeemer(capability: [.unsupported])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        harness.flow.beginSignIn()
        await harness.waitForSession()

        #expect(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL) == nil)
        #expect(await redeemer.capabilityChecks == 1)
        harness.flow.cancelSignIn()
    }

    @Test func aRememberedOriginNeverProbesItsWayDown() async {
        // An earlier launch saw the code; this one's origin now says no or nothing.
        let store = FakeKeyValueStore()
        HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange").recordSupported(origin: "https://example.test")
        let redeemer = FakeCodeRedeemer(capability: [.unsupported])
        let harness = HostBrowserSignInFlowHarness(
            user: user,
            codeRedeemer: redeemer,
            codeExchangeMemory: HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange")
        )

        harness.flow.beginSignIn()
        await harness.waitForSession()

        #expect(Self.query("code_challenge", in: harness.factory.sessions[0].signInURL) != nil)
        #expect(await redeemer.capabilityChecks == 0)
        let tokens = harness.callbackURL(state: harness.callbackState(harness.factory.sessions[0]))
        #expect(await harness.flow.handleCallbackURL(tokens) == false)
        harness.flow.cancelSignIn()
    }

    @Test func aSupportedAnswerIsRememberedForTheNextLaunch() async {
        let store = FakeKeyValueStore()
        let memory = HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange")
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: FakeCodeRedeemer(), codeExchangeMemory: memory)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.flow.cancelSignIn()

        #expect(HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange")
            .supportsCodeExchange(origin: "https://example.test"))
    }

    // MARK: Redemption lifetime

    @Test func cancelDuringRedemptionCancelsItAndStaysSignedOut() async {
        let redeemer = HangingCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))
        await redeemer.waitUntilStarted()
        harness.flow.cancelSignIn()

        #expect(await attempt.value == false)
        #expect(await redeemer.wasCancelled)
        #expect(harness.flow.isSigningIn == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == nil)
    }

    @Test func cancelDuringTheRetryWaitStopsRetrying() async {
        let clock = ManualTestClock()
        let redeemer = AlwaysTransientCodeRedeemer(clock: clock)
        let harness = HostBrowserSignInFlowHarness(user: user, clock: clock, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))
        await clock.waitUntilSleeper(dueWithin: .seconds(3))
        harness.flow.cancelSignIn()

        #expect(await attempt.value == false)
        #expect(await redeemer.redemptions == 1)
        #expect(harness.flow.lastFailure == nil)
    }

    @Test func noRetryStartsAfterTheCodeLifetime() async {
        // The first request alone outlasts the budget: the code is gone by now.
        let clock = ManualTestClock()
        let redeemer = AlwaysTransientCodeRedeemer(clock: clock, elapsedPerRequest: .seconds(55))
        let harness = HostBrowserSignInFlowHarness(user: user, clock: clock, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 600) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value == false)
        #expect(await redeemer.redemptions == 1)
        #expect(harness.flow.lastFailure == .networkError)
    }

    // MARK: Manual URL

    @Test func manualSignInURLReadsCannotPushOutTheLiveVerifier() async throws {
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        await redeemer.expect(challenge: Self.query("code_challenge", in: session.signInURL))

        let first = try #require(await harness.flow.manualSignInURL)
        for _ in 0..<(HostBrowserHandoffModes.capacity * 3) {
            #expect(await harness.flow.manualSignInURL == first)
        }
        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(await redeemer.redemptions.count == 1)
    }

    @Test func theFirstManualURLWaitsForTheCapabilityAnswer() async throws {
        // Before any attempt has asked, the manual URL still gets the code mode,
        // and the attempt that adopts its state redeems with that verifier.
        let redeemer = FakeCodeRedeemer()
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        let manualURL = try #require(await harness.flow.manualSignInURL)
        let challenge = try #require(Self.query("code_challenge", in: manualURL))
        await redeemer.expect(challenge: challenge)
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        #expect(Self.query("code_challenge", in: session.signInURL) == challenge)

        session.deliver(Self.codeCallback(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(await redeemer.capabilityChecks == 1)
    }

    @Test func noManualURLWhenTheOriginGivesNoAnswer() async {
        let redeemer = FakeCodeRedeemer(capability: [.unknown])
        let harness = HostBrowserSignInFlowHarness(user: user, codeRedeemer: redeemer)

        #expect(await harness.flow.manualSignInURL == nil)
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

    @Test func redemptionRequestsTimeOutWellInsideTheCodeLifetime() async throws {
        let captured = Captured()
        _ = try await Self.redeemer(status: 200, body: #"{"refresh_token":"r","access_token":"a"}"#, captured: captured)
            .redeem(code: "c", verifier: "v")
        #expect(try #require(captured.request).timeoutInterval == 10)
    }

    @Test func capabilityIsAskedWithAGetAndNeedsS256() async throws {
        let captured = Captured()
        #expect(await Self.redeemer(status: 200, body: #"{"pkce":["S256"]}"#, captured: captured).codeExchangeCapability() == .supported)
        let request = try #require(captured.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://cmux.test/api/native/token")
        #expect(request.httpBody == nil)
        #expect(Self.redeemer(status: 200, body: "").signInOrigin == "https://cmux.test")
    }

    @Test func onlyA404OrAValidAnswerWithoutS256MeansUnsupported() async {
        #expect(await Self.redeemer(status: 404, body: "Not Found").codeExchangeCapability() == .unsupported)
        #expect(await Self.redeemer(status: 200, body: #"{"pkce":[]}"#).codeExchangeCapability() == .unsupported)
        #expect(await Self.redeemer(status: 200, body: #"{"pkce":["plain"]}"#).codeExchangeCapability() == .unsupported)
    }

    @Test func everythingElseIsUnknown() async {
        for status in [500, 502, 503, 401, 403, 429] {
            #expect(await Self.redeemer(status: status, body: "").codeExchangeCapability() == .unknown)
        }
        #expect(await Self.redeemer(status: 200, body: "<html>sign in</html>").codeExchangeCapability() == .unknown)
        #expect(await Self.redeemer(status: 200, body: #"{"other":true}"#).codeExchangeCapability() == .unknown)
        for error in [URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.serverCertificateUntrusted)] {
            let failing = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://cmux.test")!, scheme: "cmux") { _ in
                throw error
            }
            #expect(await failing.codeExchangeCapability() == .unknown)
        }
        // A followed redirect: the answer came from another URL, even a 404 or a valid body.
        for (status, body) in [(404, "Not Found"), (200, #"{"pkce":[]}"#)] {
            let redirected = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://cmux.test")!, scheme: "cmux") { _ in
                let elsewhere = URL(string: "https://portal.example/login")!
                return (Data(body.utf8), HTTPURLResponse(url: elsewhere, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            #expect(await redirected.codeExchangeCapability() == .unknown)
        }
        // Plain HTTP to another host is never a definitive answer.
        let insecure = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "http://cmux.test")!, scheme: "cmux") { request in
            (Data("Not Found".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await insecure.codeExchangeCapability() == .unknown)
    }

    @Test func rememberedOriginsPersistInTheAuthStore() {
        let store = FakeKeyValueStore()
        let memory = HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange")
        #expect(memory.supportsCodeExchange(origin: "https://cmux.com") == false)
        memory.recordSupported(origin: "https://cmux.com")
        memory.recordSupported(origin: "https://cmux.com")
        memory.recordSupported(origin: "https://staging.example")

        let relaunched = HostBrowserCodeExchangeMemory(keyValueStore: store, key: "code-exchange")
        #expect(relaunched.supportsCodeExchange(origin: "https://cmux.com"))
        #expect(relaunched.supportsCodeExchange(origin: "https://staging.example"))
        #expect(relaunched.supportsCodeExchange(origin: "https://other.example") == false)
    }

    @Test func aCancelledRequestIsACancellationNotANetworkError() async {
        let redeemer = NativeSignInCodeRedeemer(authWebOrigin: URL(string: "https://cmux.test")!, scheme: "cmux") { _ in
            throw URLError(.cancelled)
        }
        await #expect(throws: AuthError.cancelled) {
            try await redeemer.redeem(code: "c", verifier: "v")
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

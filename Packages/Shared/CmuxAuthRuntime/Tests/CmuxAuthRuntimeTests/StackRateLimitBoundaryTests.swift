import CMUXAuthCore
import Foundation
import Observation
import os
import Testing
@testable import CmuxAuthRuntime

/// Behavior at the sign-in service boundary: the production Stack client,
/// the real file token store, and a real HTTP server on 127.0.0.1.
@MainActor
@Suite(.serialized)
struct StackRateLimitBoundaryTests {
    private static let userJSON = #"{"id":"user-1","primary_email":"user@example.test","display_name":"User One"}"#
    private static let edgeRateLimitPage = """
    <!DOCTYPE html><html><head><title>429 Too Many Requests</title></head>
    <body><h1>Too Many Requests</h1></body></html>
    """

    /// The edge answers the user fetch with an HTML 429 (no Retry-After), then
    /// 200. Sign-in shows the rate-limit state, never the generic server
    /// failure, keeps the callback tokens, and completes on its own retry.
    @Test func htmlRateLimitDuringSignInRetriesAndCompletes() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("GET", "/api/v1/users/me", [
            .html(429, Self.edgeRateLimitPage, headers: ["Via": "1.1 google"]),
            .json(200, Self.userJSON),
        ])
        let harness = try RealStackSignInHarness(server: server)

        let started = ContinuousClock.now
        let attempt = Task { await harness.flow.signIn(timeout: 120) }
        await harness.factory.sessionsDidReach(1)
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        await harness.waitFor { harness.flow.isRetryingAfterRateLimit }
        let limited = harness.telemetry.events
        #expect(limited.map(\.phase) == [.signInCompletion])
        guard case let .rateLimited(retryAfter, backoff, attemptNumber, bodyKind, endpoint) = limited.first?.kind else {
            Issue.record("expected a rate-limited record, got \(limited)")
            return
        }
        #expect(retryAfter == nil)
        #expect((1...2).contains(backoff))
        #expect(attemptNumber == 1)
        #expect(bodyKind == "html")
        #expect(endpoint == "/api/v1/users/me")
        #expect(harness.flow.lastFailure == .rateLimited)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")

        #expect(await attempt.value == true)
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.currentUser?.id == "user-1")
        #expect(harness.flow.lastFailure == nil)
        #expect(harness.flow.isRetryingAfterRateLimit == false)
        // One refused fetch, then the retry; team reads after sign-in also
        // read the user, so count answers by status.
        #expect(server.responseCount("GET", "/api/v1/users/me", status: 429) == 1)
        #expect(server.responseCount("GET", "/api/v1/users/me", status: 200) >= 1)
        // Backoff without Retry-After waits 1-2 s before the first retry.
        #expect(ContinuousClock.now - started >= .seconds(1))
        let records = harness.telemetry.events
        #expect(records.count == 2)
        #expect(records.last?.phase == .signInCompletion)
        guard case let .recovered(limitedFor) = records.last?.kind else {
            Issue.record("expected a recovered record, got \(records)")
            return
        }
        #expect((1...30).contains(limitedFor))
    }

    /// A JSON 429 with Retry-After is honored before the retry.
    @Test func jsonRateLimitHonorsRetryAfter() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("GET", "/api/v1/users/me", [
            .json(429, #"{"code":"RATE_LIMITED","error":"Too many requests"}"#, headers: ["Retry-After": "3"]),
            .json(200, Self.userJSON),
        ])
        let harness = try RealStackSignInHarness(server: server)

        let started = ContinuousClock.now
        let attempt = Task { await harness.flow.signIn(timeout: 120) }
        await harness.factory.sessionsDidReach(1)
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await attempt.value == true)
        #expect(ContinuousClock.now - started >= .seconds(3))
        #expect(harness.flow.lastFailure == nil)
        #expect(server.responseCount("GET", "/api/v1/users/me", status: 429) == 1)
        #expect(server.responseCount("GET", "/api/v1/users/me", status: 200) >= 1)
    }

    /// When every retry is refused, the attempt ends with the rate-limit
    /// failure (not the generic server failure) and keeps the session tokens.
    @Test func persistentRateLimitEndsAsRateLimitedNotServerError() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("GET", "/api/v1/users/me", [
            .html(429, Self.edgeRateLimitPage, headers: ["Retry-After": "0"]),
        ])
        let harness = try RealStackSignInHarness(server: server)

        let attempt = Task { await harness.flow.signIn(timeout: 120) }
        await harness.factory.sessionsDidReach(1)
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await attempt.value == false)
        #expect(harness.flow.lastFailure == .rateLimited)
        #expect(harness.flow.isRetryingAfterRateLimit == false)
        #expect(server.requestCount("GET", "/api/v1/users/me") == AuthRateLimit.maximumRetries + 1)
        #expect(await harness.tokenStore.getStoredRefreshToken() == "refresh-1")
        // Seven 429s about 1 s apart give one record per 10 s window, so
        // telemetry does not grow with the retries.
        #expect((1...2).contains(harness.telemetry.events.count))
        #expect(harness.telemetry.events.first?.phase == .signInCompletion)
    }

    /// A 429 on the team list after a session check keeps the session,
    /// suppresses the extra checks that app activation and wake would start,
    /// and retries once after Retry-After.
    @Test func rateLimitedSessionCheckBacksOffAndIgnoresActivation() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("GET", "/api/v1/users/me", [.json(200, Self.userJSON)])
        server.script("GET", "/api/v1/teams", [
            .html(429, Self.edgeRateLimitPage, headers: ["Retry-After": "2"]),
            .json(200, #"{"items":[{"id":"team-1","display_name":"Team One"}]}"#),
        ])
        let harness = try RealStackSignInHarness(server: server)
        await harness.tokenStore.seed(accessToken: harness.accessToken, refreshToken: "refresh-1")

        let started = ContinuousClock.now
        await harness.coordinator.checkExistingSession()
        #expect(harness.coordinator.isAuthenticated)
        #expect(harness.coordinator.availableTeams.isEmpty)
        #expect(harness.coordinator.teamScopeRateLimit != nil)
        #expect(harness.coordinator.hasPendingTeamScopeRecovery)
        let userFetches = server.requestCount("GET", "/api/v1/users/me")

        // App activation, wake, and network-path signals during the backoff.
        for _ in 0..<5 {
            await harness.coordinator.recoverTeamScopeIfNeeded()
        }
        #expect(server.requestCount("GET", "/api/v1/users/me") == userFetches)
        #expect(server.requestCount("GET", "/api/v1/teams") == 1)

        await harness.waitFor { !harness.coordinator.availableTeams.isEmpty }
        #expect(ContinuousClock.now - started >= .seconds(2))
        #expect(harness.coordinator.availableTeams.map(\.id) == ["team-1"])
        #expect(harness.coordinator.teamScopeRateLimit == nil)
        #expect(server.responseCount("GET", "/api/v1/teams", status: 429) == 1)
        #expect(harness.coordinator.isAuthenticated)
        let records = harness.telemetry.events
        #expect(records.map(\.phase) == [.sessionCheck, .sessionCheck])
        guard case let .rateLimited(retryAfter, backoff, attemptNumber, bodyKind, endpoint) = records.first?.kind else {
            Issue.record("expected a rate-limited record, got \(records)")
            return
        }
        #expect(retryAfter == 2)
        #expect((2...3).contains(backoff))
        #expect(attemptNumber == 1)
        #expect(bodyKind == "html")
        #expect(endpoint == "/api/v1/teams")
        guard case .recovered = records.last?.kind else {
            Issue.record("expected a recovered record, got \(records)")
            return
        }
    }

    /// Sign-out during the rate-limit wait ends the wait at once and the
    /// retry never reaches the server.
    @Test func signOutCancelsTheRateLimitWait() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("GET", "/api/v1/users/me", [
            .html(429, Self.edgeRateLimitPage, headers: ["Retry-After": "100"]),
            .json(200, Self.userJSON),
        ])
        let harness = try RealStackSignInHarness(server: server)

        let attempt = Task { await harness.flow.signIn(timeout: 120) }
        await harness.factory.sessionsDidReach(1)
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))
        await harness.waitFor { harness.flow.isRetryingAfterRateLimit }

        let started = ContinuousClock.now
        await harness.flow.signOut()
        #expect(await attempt.value == false)
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(harness.flow.isRetryingAfterRateLimit == false)
        #expect(harness.coordinator.isAuthenticated == false)
        #expect(server.requestCount("GET", "/api/v1/users/me") == 1)
    }
}

/// The macOS hosted-browser sign-in wired to the production Stack client.
/// Only the browser window is a fake; every HTTP call reaches the server.
@MainActor
private struct RealStackSignInHarness {
    let flow: HostBrowserSignInFlow
    let coordinator: AuthCoordinator
    let tokenStore: FileStackTokenStore
    let factory: FakeBrowserAuthSessionFactory
    let telemetry: TelemetryRecorder
    let accessToken = testAccessJWT(issuedSecondsAgo: 5, expiresInSeconds: 600)

    init(server: LocalStackHTTPServer) throws {
        let tokenStore = FileStackTokenStore(directory: try makeBoundaryTestDirectory())
        let client = StackAuthClient(
            config: .test,
            tokenStore: .custom(tokenStore),
            baseURL: server.baseURL,
            noAutomaticPrefetch: true
        )
        let keyValues = FakeKeyValueStore()
        let telemetry = TelemetryRecorder()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: keyValues, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: keyValues, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: keyValues, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain(),
            rateLimitTelemetry: telemetry.source
        )
        let factory = FakeBrowserAuthSessionFactory()
        flow = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: factory,
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\($0)")! },
            callbackScheme: { "cmux-dev" },
            openExternalURL: { _ in true }
        )
        self.coordinator = coordinator
        self.telemetry = telemetry
        self.tokenStore = tokenStore
        self.factory = factory
    }

    func callbackURL(state: String) -> URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=\(accessToken)&cmux_auth_state=\(state)")!
    }

    func callbackState(_ session: FakeBrowserAuthSession) -> String {
        URLComponents(url: session.signInURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value ?? ""
    }

    /// Suspends until `condition` (over observable flow or coordinator
    /// state) holds, with a deadline.
    func waitFor(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async {
        let watchdog = failAfterDeadline(timeout) { "Timed out waiting for sign-in state" }
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
        watchdog.cancel()
    }
}

/// Collects the rate-limit records one harness's flows emit.
private final class TelemetryRecorder: Sendable {
    let source = StackRateLimitTelemetry()
    private let recorded = OSAllocatedUnfairLock(initialState: [StackRateLimitTelemetryEvent]())

    init() {
        source.setSink { [recorded] event in recorded.withLock { $0.append(event) } }
    }

    var events: [StackRateLimitTelemetryEvent] { recorded.withLock { $0 } }
}

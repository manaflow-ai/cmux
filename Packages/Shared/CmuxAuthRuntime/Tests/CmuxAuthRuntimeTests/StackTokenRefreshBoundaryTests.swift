import Foundation
import os
import Testing
@testable import CmuxAuthRuntime

/// Token refresh cadence at the sign-in service boundary: the production
/// Stack client and file token store against a real HTTP server.
@Suite(.serialized)
struct StackTokenRefreshBoundaryTests {
    private static let edgeRateLimitPage = "<!DOCTYPE html><html><body><h1>Too Many Requests</h1></body></html>"

    /// A stored token far from expiry is served without a refresh, even when
    /// it was issued minutes ago (the old rule refreshed after 75 s).
    @Test func tokenFarFromExpiryIsNotRefreshed() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        let directory = try makeBoundaryTestDirectory()
        let store = FileStackTokenStore(directory: directory)
        let access = testAccessJWT(issuedSecondsAgo: 300, expiresInSeconds: 300)
        await store.seed(accessToken: access, refreshToken: "refresh-1")
        let client = StackAuthClient(
            config: .test, tokenStore: .custom(store), baseURL: server.baseURL, noAutomaticPrefetch: true
        )

        for _ in 0..<5 {
            #expect(try await client.resolvedAccessToken(forceRefresh: false) == access)
        }
        #expect(server.requestCount("POST", "/api/v1/auth/oauth/token") == 0)
    }

    /// A token inside the refresh lead is refreshed once, shared by every
    /// concurrent caller.
    @Test func nearExpiryRefreshIsSharedByConcurrentCallers() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        let minted = testAccessJWT(issuedSecondsAgo: 0, expiresInSeconds: 600)
        server.script("POST", "/api/v1/auth/oauth/token", [
            .json(200, #"{"access_token":"\#(minted)"}"#),
        ])
        let directory = try makeBoundaryTestDirectory()
        let store = FileStackTokenStore(directory: directory)
        await store.seed(
            accessToken: testAccessJWT(issuedSecondsAgo: 570, expiresInSeconds: 30),
            refreshToken: "refresh-1"
        )
        let client = StackAuthClient(
            config: .test, tokenStore: .custom(store), baseURL: server.baseURL, noAutomaticPrefetch: true
        )

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.resolvedAccessToken(forceRefresh: false) }
            }
            var results: [String?] = []
            for try await token in group { results.append(token) }
            return results
        }
        #expect(tokens.allSatisfy { $0 == minted })
        #expect(server.requestCount("POST", "/api/v1/auth/oauth/token") == 1)
        #expect(await store.getStoredAccessToken() == minted)
    }

    /// A rate-limited refresh keeps the session and the still-valid token,
    /// and later callers do not hit the server again inside Retry-After.
    @Test func rateLimitedRefreshKeepsSessionAndBacksOff() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("POST", "/api/v1/auth/oauth/token", [
            .html(429, Self.edgeRateLimitPage, headers: ["Retry-After": "120"]),
        ])
        let directory = try makeBoundaryTestDirectory()
        let store = FileStackTokenStore(directory: directory)
        let access = testAccessJWT(issuedSecondsAgo: 570, expiresInSeconds: 30)
        await store.seed(accessToken: access, refreshToken: "refresh-1")
        let client = StackAuthClient(
            config: .test, tokenStore: .custom(store), baseURL: server.baseURL, noAutomaticPrefetch: true
        )

        for _ in 0..<5 {
            #expect(try await client.resolvedAccessToken(forceRefresh: false) == access)
        }
        #expect(server.requestCount("POST", "/api/v1/auth/oauth/token") == 1)
        #expect(await store.getStoredRefreshToken() == "refresh-1")
        #expect(await store.getStoredAccessToken() == access)
    }

    /// A rate-limited refresh produces one token-refresh record with the
    /// 429's evidence, and calls inside the cooldown add none. (The SDK's
    /// RateLimitRetryTests cover the recovery signal with a virtual clock.)
    @Test func rateLimitedRefreshIsReportedOnce() async throws {
        let server = try LocalStackHTTPServer()
        try await server.start()
        defer { server.stop() }
        server.script("POST", "/api/v1/auth/oauth/token", [
            .html(429, Self.edgeRateLimitPage, headers: ["Retry-After": "90"]),
        ])
        let directory = try makeBoundaryTestDirectory()
        let store = FileStackTokenStore(directory: directory)
        let access = testAccessJWT(issuedSecondsAgo: 570, expiresInSeconds: 30)
        await store.seed(accessToken: access, refreshToken: "refresh-1")
        let client = StackAuthClient(
            config: .test, tokenStore: .custom(store), baseURL: server.baseURL, noAutomaticPrefetch: true
        )
        // The SDK reports refresh 429s to the process-wide instance. Drain
        // anything buffered by earlier tests and end their period first.
        let telemetry = StackRateLimitTelemetry.shared
        telemetry.setSink { _ in }
        telemetry.succeeded(.tokenRefresh)
        let recorded = OSAllocatedUnfairLock(initialState: [StackRateLimitTelemetryEvent]())
        telemetry.setSink { event in
            if event.phase == .tokenRefresh { recorded.withLock { $0.append(event) } }
        }
        defer { telemetry.setSink(nil) }

        for _ in 0..<3 {
            #expect(try await client.resolvedAccessToken(forceRefresh: false) == access)
        }
        #expect(server.requestCount("POST", "/api/v1/auth/oauth/token") == 1)

        let events = recorded.withLock { $0 }
        #expect(events.count == 1)
        guard case let .rateLimited(retryAfter, backoff, attempt, bodyKind, endpoint) = events.first?.kind else {
            Issue.record("expected a rate-limited record, got \(events)")
            return
        }
        #expect(retryAfter == 90)
        #expect(backoff == 90)
        #expect(attempt == 1)
        #expect(bodyKind == "html")
        #expect(endpoint == "/api/v1/auth/oauth/token")
    }
}

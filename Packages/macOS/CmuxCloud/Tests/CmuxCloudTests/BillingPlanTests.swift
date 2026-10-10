import CmuxCloud
import Foundation
import Testing

@Suite("Billing plan state", .serialized)
struct BillingPlanTests {
    @Test("successful response is scoped to its account")
    func successScopesAccount() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            isPro: true,
            canManageBilling: true
        )
        #expect(state.accountID == "account-a")
        #expect(state.isPro)
        #expect(state.canManageBilling)
    }

    @Test("same-account and team failure preserves the last known answer")
    func sameAccountFailurePreservesAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-a") == state)
    }

    @Test("different-team failure clears the answer")
    func differentTeamFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-b") == .unknown)
    }

    @Test("different-account failure clears the answer")
    func differentAccountFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-b") == .unknown)
    }

    @Test("explicit team lookup sends and validates the team scope")
    func explicitTeamScope() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        BillingPlanURLProtocol.response = #"{"authenticated":true,"isPro":true,"teamId":"team-b","teamPlanId":"free","teamBillingManagement":"none"}"#
        sessionConfiguration.protocolClasses = [BillingPlanURLProtocol.self]
        let client = BillingPlanClient(session: URLSession(configuration: sessionConfiguration))

        let details = try await client.fetch(
            from: URL(string: "https://cmux.example/api/billing/plan")!,
            accessToken: "access",
            refreshToken: "refresh",
            teamID: "team-b"
        )

        #expect(details.isPro)
        #expect(!details.canManageBilling)
        #expect(BillingPlanURLProtocol.lastRequest?.url?.query == "teamId=team-b")
    }

    @Test("explicit team lookup rejects a mismatched response")
    func mismatchedExplicitTeamScope() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        BillingPlanURLProtocol.response = #"{"authenticated":true,"teamId":"team-a","teamPlanId":"pro"}"#
        sessionConfiguration.protocolClasses = [BillingPlanURLProtocol.self]
        let client = BillingPlanClient(session: URLSession(configuration: sessionConfiguration))

        await #expect(throws: URLError.self) {
            _ = try await client.fetch(
                from: URL(string: "https://cmux.example/api/billing/plan")!,
                accessToken: "access",
                teamID: "team-b"
            )
        }
    }

    @Test("personal lookup ignores the route's implicit team fallback")
    func personalScopeDoesNotAdoptImplicitTeam() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        BillingPlanURLProtocol.response = #"{"authenticated":true,"isPro":false,"planId":"free","teamPlanId":"pro","teamBillingManagement":"stripe"}"#
        sessionConfiguration.protocolClasses = [BillingPlanURLProtocol.self]
        let client = BillingPlanClient(session: URLSession(configuration: sessionConfiguration))

        let details = try await client.fetch(
            from: URL(string: "https://cmux.example/api/billing/plan")!,
            accessToken: "access"
        )

        #expect(!details.isPro)
        #expect(!details.canManageBilling)
    }
}

private final class BillingPlanURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var response = ""
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.lastRequest = request
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Self.lock.withLock { Data(Self.response.utf8) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

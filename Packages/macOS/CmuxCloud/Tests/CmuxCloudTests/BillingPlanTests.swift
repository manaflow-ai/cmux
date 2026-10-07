import CmuxCloud
import Foundation
import Testing

@Suite("Billing plan state")
struct BillingPlanTests {
    @Test("successful response is scoped to its account")
    func successScopesAccount() {
        let state = BillingPlanState.unknown.applyingSuccess(
            for: "account-a",
            teamID: "team-a",
            isPro: true,
            canManageBilling: true
        )
        #expect(state.accountID == "account-a")
        #expect(state.teamID == "team-a")
        #expect(state.isPro)
        #expect(state.canManageBilling)
    }

    @Test("same-account failure preserves the last known answer")
    func sameAccountFailurePreservesAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-a") == state)
    }

    @Test("different-account failure clears the answer")
    func differentAccountFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-b", teamID: "team-a") == .unknown)
    }

    @Test("different team failure clears the answer")
    func differentTeamFailureClearsAnswer() {
        let state = BillingPlanState(accountID: "account-a", teamID: "team-a", isPro: true, canManageBilling: true)
        #expect(state.applyingFailure(for: "account-a", teamID: "team-b") == .unknown)
    }

    @Test("refresh coordinator retains same-scope answers and rejects stale responses")
    func refreshCoordinatorRetainsSameScopeAnswers() {
        var coordinator = BillingPlanRefreshCoordinator()
        let scope = BillingPlanRefreshScope(accountID: "account-a", teamID: "team-a")
        let firstRequest = coordinator.begin(scope: scope)
        coordinator.applySuccess(firstRequest, scope: scope, isPro: false, canManageBilling: false)

        let secondRequest = coordinator.begin(scope: scope)
        #expect(coordinator.isCurrent(secondRequest, scope: scope))
        coordinator.applyTransientFailure(secondRequest, scope: scope)
        #expect(coordinator.state.isPro == false)
        #expect(coordinator.state.accountID == "account-a")

        coordinator.applySuccess(firstRequest, scope: scope, isPro: true, canManageBilling: true)
        #expect(coordinator.state.isPro == false)
    }

    @Test("overlapping same-scope refresh keeps an earlier success after a later failure")
    func overlappingRefreshKeepsEarlierSuccess() {
        var coordinator = BillingPlanRefreshCoordinator()
        let scope = BillingPlanRefreshScope(accountID: "account-a", teamID: "team-a")
        let firstRequest = coordinator.begin(scope: scope)
        let secondRequest = coordinator.begin(scope: scope)

        coordinator.applyTransientFailure(secondRequest, scope: scope)
        coordinator.applySuccess(firstRequest, scope: scope, isPro: true, canManageBilling: true)

        #expect(coordinator.state.isPro)
        #expect(coordinator.state.accountID == "account-a")
    }

    @Test("refresh coordinator invalidates a changed scope")
    func refreshCoordinatorInvalidatesChangedScope() {
        var coordinator = BillingPlanRefreshCoordinator()
        let scope = BillingPlanRefreshScope(accountID: "account-a", teamID: "team-a")
        let request = coordinator.begin(scope: scope)
        coordinator.applySuccess(request, scope: scope, isPro: true, canManageBilling: true)

        coordinator.invalidateIfScopeChanged(accountID: "account-a", teamID: "team-b")
        #expect(coordinator.state == .unknown)
        #expect(!coordinator.isCurrent(request, scope: scope))
    }

    @Test("unauthenticated HTTP 200 response is rejected")
    func unauthenticatedResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        BillingPlanStubURLProtocol.responseData = Data(#"{"authenticated":false,"isPro":false,"planId":"free"}"#.utf8)
        defer { BillingPlanStubURLProtocol.responseData = nil }

        let client = BillingPlanClient(session: session)
        await #expect(throws: BillingPlanClientError.unauthenticated) {
            try await client.fetch(
                from: URL(string: "https://cmux.test/api/billing/plan")!,
                accessToken: nil
            )
        }
    }
}

private final class BillingPlanStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

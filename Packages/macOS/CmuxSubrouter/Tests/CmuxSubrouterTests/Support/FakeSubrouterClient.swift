import Foundation
@testable import CmuxSubrouter

/// A scriptable ``SubrouterClienting``: returns configured results and counts
/// calls, so store tests never touch the network.
actor FakeSubrouterClient: SubrouterClienting {
    var healthResult: Result<Bool, SubrouterClientError> = .success(true)
    var accountsResult: Result<[SubrouterAccount], SubrouterClientError> = .success([])
    var usageResult: Result<[SubrouterAccountUsageStatus], SubrouterClientError> = .success([])
    var sessionsResult: Result<[SubrouterSessionAssignment], SubrouterClientError> = .success([])
    var reloadResult: Result<SubrouterReloadResult, SubrouterClientError> =
        .success(SubrouterReloadResult(ok: true, accounts: 0, usageRefreshed: 0))

    private(set) var healthCallCount = 0
    private(set) var accountsCallCount = 0
    private(set) var usageCallCount = 0
    private(set) var sessionsCallCount = 0
    private(set) var reloadCallCount = 0
    private(set) var lastEndpoint: SubrouterEndpoint?

    func setHealthResult(_ result: Result<Bool, SubrouterClientError>) {
        healthResult = result
    }

    func setAccountsResult(_ result: Result<[SubrouterAccount], SubrouterClientError>) {
        accountsResult = result
    }

    func setUsageResult(_ result: Result<[SubrouterAccountUsageStatus], SubrouterClientError>) {
        usageResult = result
    }

    func setSessionsResult(_ result: Result<[SubrouterSessionAssignment], SubrouterClientError>) {
        sessionsResult = result
    }

    func setReloadResult(_ result: Result<SubrouterReloadResult, SubrouterClientError>) {
        reloadResult = result
    }

    var totalFetchCallCount: Int {
        healthCallCount + accountsCallCount + usageCallCount + sessionsCallCount + reloadCallCount
    }

    func health(endpoint: SubrouterEndpoint) async throws -> Bool {
        healthCallCount += 1
        lastEndpoint = endpoint
        return try healthResult.get()
    }

    func accounts(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccount] {
        accountsCallCount += 1
        lastEndpoint = endpoint
        return try accountsResult.get()
    }

    func usageStatuses(endpoint: SubrouterEndpoint) async throws -> [SubrouterAccountUsageStatus] {
        usageCallCount += 1
        lastEndpoint = endpoint
        return try usageResult.get()
    }

    func sessions(endpoint: SubrouterEndpoint) async throws -> [SubrouterSessionAssignment] {
        sessionsCallCount += 1
        lastEndpoint = endpoint
        return try sessionsResult.get()
    }

    func reloadAccounts(endpoint: SubrouterEndpoint) async throws -> SubrouterReloadResult {
        reloadCallCount += 1
        lastEndpoint = endpoint
        return try reloadResult.get()
    }
}

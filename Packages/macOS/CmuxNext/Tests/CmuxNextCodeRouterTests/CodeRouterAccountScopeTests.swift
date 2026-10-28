@testable import CmuxNextCodeRouter
import Foundation
import os
import Testing

/// Exercise the production Accounts client composition with controlled async boundaries.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CodeRouterAccountScopeTests {
    private final class Account: CodeRouterAccountSource {
        var codeRouterAccountID: String? = "first-user"
        var teamID: String? = "first-team"
        var tokenGate: Gate?

        func tokens() async throws -> (access: String, refresh: String) {
            let pair = (access: "fixture-access", refresh: "fixture-refresh")
            if let tokenGate { await tokenGate.pause() }
            return pair
        }
    }

    private actor Gate {
        private let arrived = AsyncStream<Void>.makeStream()
        private var release: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { release = $0; arrived.continuation.yield(()) }
        }

        func waitUntilPaused() async {
            var iterator = arrived.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        func resume() { release?.resume(); release = nil }
    }

    private final class Transport: URLProtocol, @unchecked Sendable {
        static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.withLock { $0.append(request) }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private enum Change: CaseIterable { case user, team, personal, signedOut }

    private func change(_ account: Account, to change: Change) {
        switch change {
        case .user: account.codeRouterAccountID = "second-user"
        case .team: account.teamID = "second-team"
        case .personal: account.teamID = nil
        case .signedOut: account.codeRouterAccountID = nil
        }
    }

    private func fixture(_ account: Account) throws -> (CodeRouterClient, URLSession) {
        Transport.requests.withLock { $0.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Transport.self]
        let session = URLSession(configuration: config)
        let client = CodeRouterClient(baseURL: try #require(URL(string: "https://scope.invalid")), account: account,
                                      labeler: { AccountLabeler(salt: Data(repeating: 1, count: 32)) }, session: session)
        return (client, session)
    }

    private func upload(_ client: CodeRouterClient) async -> Bool {
        do { try await client.add(.apiKey(serverProvider: "openai", key: "fixture-provider-key", label: nil)); return true }
        catch { return false }
    }

    @Test(arguments: Change.allCases)
    private func switchingDuringCredentialAcquisitionUploadsNothing(_ change: Change) async throws {
        let account = Account()
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        let acquisition = Gate()
        let operation = Task {
            // AccountsService creates this client before awaiting Keychain/provider acquisition.
            await acquisition.pause()
            return await upload(client)
        }
        await acquisition.waitUntilPaused()
        self.change(account, to: change)
        await acquisition.resume()
        #expect(await !operation.value)
        #expect(Transport.requests.withLock { $0.count } == 0)
    }

    @Test(arguments: Change.allCases)
    private func switchingBetweenTokenAndTeamReadsUploadsNothing(_ change: Change) async throws {
        let account = Account()
        let gate = Gate()
        account.tokenGate = gate
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        let operation = Task { await upload(client) }
        await gate.waitUntilPaused()
        self.change(account, to: change)
        await gate.resume()
        #expect(await !operation.value)
        #expect(Transport.requests.withLock { $0.count } == 0)
    }

    @Test(arguments: [false, true])
    func unchangedScopeUploadsToTheSelectedTeam(personal: Bool) async throws {
        let account = Account()
        if personal { account.teamID = nil }
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        #expect(await upload(client))
        let requests = Transport.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-Cmux-Team-Id") == account.teamID)
        #expect(requests.first?.httpMethod == "POST")
    }
}

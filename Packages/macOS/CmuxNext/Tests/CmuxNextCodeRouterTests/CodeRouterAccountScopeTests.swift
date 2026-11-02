@testable import CmuxNextCodeRouter
import Foundation
import os
import Testing

/// Exercise the production Accounts client composition with controlled async boundaries.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CodeRouterAccountScopeTests {
    @MainActor private final class Account: CodeRouterAccountSource {
        var codeRouterAccountID: String? = "first-user"
        var teamID: String? = "first-team"
        var tokenGate: Gate?
        var cancelTokenRead = false
        private var scopeVersion = (session: UInt64(0), team: UInt64(0))

        var codeRouterScopeVersion: (session: UInt64, team: UInt64) { scopeVersion }

        func advanceSession() { scopeVersion.session &+= 1 }
        func advanceTeam() { scopeVersion.team &+= 1 }

        func tokens() async throws -> (access: String, refresh: String) {
            let pair = (access: "fixture-access", refresh: "fixture-refresh")
            if let tokenGate { await tokenGate.pause() }
            if cancelTokenRead { throw CancellationError() }
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
        case .user:
            account.advanceSession()
            account.codeRouterAccountID = "second-user"
        case .team:
            account.advanceTeam()
            account.teamID = "second-team"
        case .personal:
            account.advanceTeam()
            account.teamID = nil
        case .signedOut:
            account.advanceSession()
            account.codeRouterAccountID = nil
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

    @Test func startingSignedOutReportsNotSignedIn() async throws {
        let account = Account()
        account.codeRouterAccountID = nil
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.request("GET", "/api/coderouter/accounts")
            Issue.record("a signed-out account unexpectedly made a request")
        } catch let error as CodeRouterError {
            #expect(error == .notSignedIn)
            #expect(Transport.requests.withLock { $0.isEmpty })
        }
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

    @Test func returningToOriginalIdentifiersAfterScopeSwitchUploadsNothing() async throws {
        let account = Account()
        let gate = Gate()
        account.tokenGate = gate
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        let operation = Task { await upload(client) }
        await gate.waitUntilPaused()
        account.advanceSession()
        account.codeRouterAccountID = "second-user"
        account.advanceSession()
        account.codeRouterAccountID = "first-user"
        await gate.resume()
        #expect(await !operation.value)
        #expect(Transport.requests.withLock { $0.count } == 0)
    }

    @Test func cancelledTokenReadAfterScopeSwitchReportsScopeChanged() async throws {
        let account = Account()
        let gate = Gate()
        account.tokenGate = gate
        account.cancelTokenRead = true
        let (client, session) = try fixture(account)
        defer { session.invalidateAndCancel() }
        let operation = Task {
            do {
                _ = try await client.request("GET", "/api/coderouter/accounts")
                return CodeRouterError.transport("request unexpectedly succeeded")
            } catch let error as CodeRouterError {
                return error
            } catch {
                return CodeRouterError.transport(String(describing: error))
            }
        }
        await gate.waitUntilPaused()
        account.advanceSession()
        account.codeRouterAccountID = "second-user"
        await gate.resume()
        #expect(await operation.value == .scopeChanged)
        #expect(Transport.requests.withLock { $0.count } == 0)
    }

    @Test func finalScopeRejectionUploadsNothing() async throws {
        Transport.requests.withLock { $0.removeAll() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Transport.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CodeRouterClient(
            baseURL: try #require(URL(string: "https://scope.invalid")),
            tokens: { (access: "fixture-access", refresh: "fixture-refresh") },
            teamID: { "first-team" },
            labeler: { AccountLabeler(salt: Data(repeating: 1, count: 32)) },
            session: session,
            scopeValidator: { throw CodeRouterError.scopeChanged }
        )
        #expect(await !upload(client))
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

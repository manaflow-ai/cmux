import CmuxInstallAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// The before run of `fault mint-stall` (not for merge): on the feat-cmux-next base, MacInstallIdentity.installToken()
/// is `client.installToken()`, so these drive that InstallAuthClient with the same clock, owner and stalls as the
/// head's MacInstallMintStallTests.
@Suite struct MacInstallMintStallTests {
    private func client(_ owner: MintStallOwner, root: URL, clock: MintStallClock) -> InstallAuthClient {
        InstallAuthClient(transport: owner, signer: MacInstallStore.files(directory: root).signer(for: "stack_1"),
                          sessionToken: { "test-session" }, stackUser: "stack_1", deviceName: "Test Mac",
                          clientVersion: "2.4.0", record: nil, profile: .mac, now: { clock.now })
    }

    @Test func aStalledRenewalNeverHoldsACallWhileTheHeldTokenIsValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        let identity = client(owner, root: root, clock: clock)
        let first = try await identity.installToken()

        clock.advance(500)
        await owner.stallTokens(for: .seconds(30))
        let started = ContinuousClock.now
        let token = try await identity.installToken()
        #expect(token == first)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aStalledMintWithNoUsableTokenNamesItsStepWithinTheBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        let identity = client(owner, root: root, clock: clock)
        _ = try await identity.installToken()

        clock.advance(600)
        await owner.stallTokens(for: .seconds(30))
        let started = ContinuousClock.now
        do {
            _ = try await identity.installToken()
            Issue.record("a stalled mint answered a token")
        } catch {
            #expect(String(describing: error).contains("POST /v1/auth/token"))
        }
        #expect(ContinuousClock.now - started < .seconds(17))
    }
}

nonisolated final class MintStallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var now: Date { Date() + lock.withLock { offset } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

actor MintStallOwner: InstallAuthTransport {
    private let owner = MacTeamAuthOwner()
    private let clock: MintStallClock
    private var stall: Duration?

    init(clock: MintStallClock) { self.clock = clock }

    func stallTokens(for duration: Duration?) { stall = duration }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        if path == "/v1/auth/token", let stall { try await Task.sleep(for: stall) }
        let answer = try await owner.post(path, json: json, bearer: bearer, headers: headers)
        // The token's life runs on the test's clock: 600 s from its now.
        guard path == "/v1/auth/token", var body = try JSONSerialization.jsonObject(with: answer.body) as? [String: Any] else {
            return answer
        }
        body["expires_at"] = clock.now.addingTimeInterval(600).timeIntervalSince1970 * 1000
        return (answer.status, try JSONSerialization.data(withJSONObject: body))
    }

    func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        try await owner.get(path, bearer: bearer, headers: headers)
    }
}

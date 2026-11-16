import CmuxInstallAuthCore
import CmuxNextCloud
import Foundation
import Testing

/// `fault mint-stall` (remote-cloud-durability F13; compendium cloud-chat "machine list loaded=False"): the
/// install token's mint hangs for 30 s. A caller holding a valid token answers at once while the renewal runs
/// beside it (the machine list loads); a caller with no usable token hears the stalled step within Rust's
/// bound (`signin::MINT_BOUND`, 15 s), never "the cmux API did not answer" after the relay's own timeout.
@Suite struct MacInstallMintStallTests {
    @Test func aStalledRenewalNeverHoldsACallWhileTheHeldTokenIsValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        let identity = MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac",
                                          clientVersion: "2.4.0", now: { clock.now })
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let first = try await identity.installToken()

        // 500 s into a 540 s token: past 2/3 of its life, 40 s left.
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
        let identity = MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac",
                                          clientVersion: "2.4.0", now: { clock.now })
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })

        // The held token expired (a Mac that slept); the next mint hangs 30 s.
        clock.advance(600)
        await owner.stallTokens(for: .seconds(30))
        let started = ContinuousClock.now
        do {
            _ = try await identity.installToken()
            Issue.record("a stalled mint answered a token")
        } catch let stalled as MacInstallIdentity.MintStalled {
            #expect(stalled.refusal["code"]?.stringValue == "credential.minting")
            #expect(stalled.description.contains("POST /v1/auth/token"))
            #expect(!stalled.description.contains("did not answer"))
        }
        #expect(ContinuousClock.now - started < .seconds(17))

        // The stalled mint was replaced: once the owner answers again, the next caller gets a token at once.
        await owner.stallTokens(for: nil)
        let next = ContinuousClock.now
        _ = try await identity.installToken()
        #expect(ContinuousClock.now - next < .seconds(2))
    }
}

/// The wall clock, moved ahead by hand.
nonisolated final class MintStallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var now: Date { Date() + lock.withLock { offset } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

/// ``MacTeamAuthOwner`` (it verifies the real Mac signer) whose `/v1/auth/token` can hang.
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

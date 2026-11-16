import CmuxInstallAuthCore
import CmuxNextCloud
import Foundation
import Testing

/// `fault mint-stall` (remote-cloud-durability F13; compendium cloud-chat "machine list loaded=False"): the
/// install token's mint hangs. A caller holding a valid token answers while the renewal hangs beside it (the
/// machine list loads); a caller with no usable token hears the stalled step once Rust's bound
/// (`signin::MINT_BOUND`, 15 s) passes, never "the cmux API did not answer" after the relay's own timeout.
/// Ordered by events, not timings: the owner holds `/v1/auth/token` until the test releases it, and the bound
/// passes on the test's clock once the mint is held there. A caller that waits on the held mint never returns,
/// so the time limit fails it.
@Suite(.timeLimit(.minutes(1))) struct MacInstallMintStallTests {
    @Test func aStalledRenewalNeverHoldsACallWhileTheHeldTokenIsValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        let identity = MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac",
                                          clientVersion: "2.4.0", now: { clock.now })
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let first = try await identity.installToken()

        // 500 s in: past 2/3 of the token's life and inside the old path's last-60-s renewal. The renewal is held
        // at POST /v1/auth/token; the old path waited on it.
        clock.advance(500)
        await owner.holdTokens()
        let token = try await identity.installToken()
        #expect(token == first)
        #expect(await owner.mintHeld(), "the renewal did not start beside the held token")
        await owner.releaseTokens()
    }

    @Test func aStalledMintWithNoUsableTokenNamesItsStepWithinTheBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        // A waiter's deadline passes on the test's clock once the mint is held at the owner.
        let identity = MacInstallIdentity(
            store: .files(directory: root), transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0",
            now: { clock.now },
            sleep: { span in
                if await owner.mintHeld() { clock.advance(span) } else { try? await Task.sleep(for: .seconds(span)) }
            })
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })

        // The held token expired (a Mac that slept); the next mint hangs at POST /v1/auth/token.
        clock.advance(600)
        await owner.holdTokens()
        do {
            _ = try await identity.installToken()
            Issue.record("a stalled mint answered a token")
        } catch let stalled as MacInstallIdentity.MintStalled {
            #expect(stalled.refusal["code"]?.stringValue == "credential.minting")
            #expect(stalled.description.contains("POST /v1/auth/token"))
            #expect(!stalled.description.contains("did not answer"))
        }

        // The stalled mint was replaced: once the owner answers again, the next caller gets a token.
        await owner.releaseTokens()
        _ = try await identity.installToken()
    }
}

/// The wall clock, moved ahead by hand.
nonisolated final class MintStallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var now: Date { Date() + lock.withLock { offset } }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
}

/// ``MacTeamAuthOwner`` (it verifies the real Mac signer) whose `/v1/auth/token` can be held until released.
actor MintStallOwner: InstallAuthTransport {
    private let owner = MacTeamAuthOwner()
    private let clock: MintStallClock
    private var holding = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [CheckedContinuation<Bool, Never>] = []

    init(clock: MintStallClock) { self.clock = clock }

    func holdTokens() { holding = true }

    func releaseTokens() {
        holding = false
        let requests = held, waiters = heldWaiters
        held = [:]
        heldWaiters = []
        for request in requests.values { request.resume() }
        for waiter in waiters { waiter.resume(returning: false) }
    }

    /// True once a `/v1/auth/token` request is held; false when nothing is held or it is released first.
    func mintHeld() async -> Bool {
        guard holding else { return false }
        if !held.isEmpty { return true }
        return await withCheckedContinuation { heldWaiters.append($0) }
    }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        if path == "/v1/auth/token", holding { try await hold() }
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

    /// Holds one request until ``releaseTokens()`` or its task's cancel (a stalled mint the lease replaced).
    private func hold() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { held[id] = continuation }
                let waiters = heldWaiters
                heldWaiters = []
                for waiter in waiters { waiter.resume(returning: true) }
            }
        } onCancel: {
            Task { await self.cancelHold(id) }
        }
        try Task.checkCancellation()
    }

    private func cancelHold(_ id: UUID) { held.removeValue(forKey: id)?.resume() }
}

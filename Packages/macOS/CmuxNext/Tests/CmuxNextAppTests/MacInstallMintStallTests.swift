import CmuxInstallAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// The before run of `fault mint-stall` (not for merge): on the feat-cmux-next base, MacInstallIdentity.installToken()
/// is `client.installToken()`, so these drive that InstallAuthClient with the same clock and held owner as the head's
/// MacInstallMintStallTests. A caller that waits on the held mint never returns, and the time limit fails it.
@Suite(.timeLimit(.minutes(1))) struct MacInstallMintStallTests {
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
        await owner.holdTokens()
        let token = try await identity.installToken()
        #expect(token == first)
        await owner.releaseTokens()
    }

    @Test func aStalledMintWithNoUsableTokenNamesItsStepWithinTheBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MintStallClock(), owner = MintStallOwner(clock: clock)
        let identity = client(owner, root: root, clock: clock)
        _ = try await identity.installToken()

        clock.advance(600)
        await owner.holdTokens()
        do {
            _ = try await identity.installToken()
            Issue.record("a stalled mint answered a token")
        } catch {
            #expect(String(describing: error).contains("POST /v1/auth/token"))
        }
        await owner.releaseTokens()
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

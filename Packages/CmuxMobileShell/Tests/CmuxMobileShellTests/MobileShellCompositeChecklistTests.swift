import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// End-to-end coverage that a real pairing attempt drives the network /
/// authentication / trust checklist to the right per-gate state (issue #6084):
/// the offline preflight, an on-the-wire auth rejection, an account mismatch, and
/// a clean success each resolve a distinct shape. Reuses the scripted-host
/// harness from `MobileShellRenderGridLivenessTestSupport.swift`.
@Suite @MainActor struct MobileShellCompositeChecklistTests {
    @Test func offlinePreflightFailsOnlyTheNetworkGate() async throws {
        let store = MobileShellComposite(reachability: StubReachability(online: false))
        store.signIn()
        // A non-loopback host triggers the reachability preflight (loopback routes
        // skip it), so the attempt short-circuits before any transport work.
        await store.connectManualHost(name: "Work Mac", host: "100.64.0.1", port: 58_465)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network.isFailed)
        #expect(checklist.authentication == .pending)
        #expect(checklist.trust == .pending)
    }

    @Test func authRejectionClearsNetworkThenFailsAuthenticationGate() async throws {
        let store = makeStore(errorCode: "unauthorized", message: "invalid token")
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication.isFailed)
        #expect(checklist.trust == .pending)
    }

    @Test func accountMismatchClearsNetworkAndAuthThenFailsTrustGate() async throws {
        let store = makeStore(errorCode: "account_mismatch", message: "different account")
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .failed)
        let checklist = try #require(store.pairingChecklist)
        #expect(checklist.network == .succeeded)
        #expect(checklist.authentication == .succeeded)
        #expect(checklist.trust.isFailed)
    }

    @Test func successfulPairingClearsEveryGate() async throws {
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
            now: { TestClock().now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let result = await connectAcceptingVersionWarning(store, try attachURL(for: makeTicket(clock: TestClock())))
        #expect(result == .connected)
        #expect(store.pairingChecklist == .connected)
    }

    // MARK: - Harness

    private func makeStore(errorCode: String?, message: String) -> MobileShellComposite {
        let runtime = LivenessTestRuntime(
            transportFactory: ChecklistErrorTransportFactory(code: errorCode, message: message),
            now: { TestClock().now },
            pairingRequestTimeoutNanoseconds: 5_000_000_000
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        return store
    }

    /// Connect through the QR path, accepting the Mac/iPhone compatibility warning
    /// if prompted (the scripted ticket carries no compatibility version, which the
    /// host treats as a mismatch). Mirrors the user tapping "Continue anyway".
    private func connectAcceptingVersionWarning(
        _ store: MobileShellComposite,
        _ url: String
    ) async -> MobilePairingURLConnectionResult {
        let result = await store.connectPairingURLResult(url)
        guard result == .needsUserApproval else { return result }
        return await store.acceptPairingVersionWarning()
    }
}

/// Reports a fixed online/offline verdict and never emits a path change, for the
/// reachability preflight test.
struct StubReachability: ReachabilityProviding {
    let online: Bool
    var isOnline: Bool { get async { online } }
    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// A transport that answers every framed request with one configured RPC error
/// frame, so a pairing attempt fails at the authentication/trust gate without a
/// real host. Mirrors the receive/deliver pump of `LivenessTransport`.
actor ChecklistErrorTransport: CmxByteTransport {
    private let code: String?
    private let message: String
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(code: String?, message: String) {
        self.code = code
        self.message = message
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            guard let id = parsed?["id"] as? String else { continue }
            var error: [String: Any] = ["message": message]
            if let code {
                error["code"] = code
            }
            let envelope: [String: Any] = ["id": id, "ok": false, "error": error]
            guard let frame = try? MobileSyncFrameCodec.encodeFrame(
                JSONSerialization.data(withJSONObject: envelope)
            ) else { continue }
            deliver(frame)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }
}

struct ChecklistErrorTransportFactory: CmxByteTransportFactory {
    let code: String?
    let message: String

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ChecklistErrorTransport(code: code, message: message)
    }
}

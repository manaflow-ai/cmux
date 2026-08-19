import Foundation

@testable import CmuxPeerTransport

/// Shared helpers for live-endpoint tests.
enum EndpointTestSupport {
    /// A fresh random ed25519 seed (any 32 bytes are a valid seed).
    static func randomSecret() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// A syntactically valid but unreachable endpoint ID: derive it from a
    /// throwaway endpoint, then close that endpoint. (Random bytes are NOT a
    /// valid ed25519 public key, so IDs must come from a real key.)
    static func unreachableEndpointID() async throws -> String {
        let throwaway = PeerEndpointManager()
        _ = try await throwaway.activate(
            secretKey: randomSecret(), relays: [], directOnly: true
        )
        guard let id = await throwaway.endpointID else {
            throw SupportFailure(reason: "throwaway manager has no endpointID")
        }
        await throwaway.deactivate()
        return id
    }

    /// Dial hints that reach `manager` from within the same process:
    /// loopback rewrites of its bound sockets first (wildcard binds like
    /// `0.0.0.0:port` are not dialable as-is), then whatever direct
    /// addresses the endpoint advertises.
    static func loopbackHints(for manager: PeerEndpointManager) async -> [String] {
        var hints: [String] = []
        for socket in await manager.boundSocketAddresses() {
            guard let colon = socket.lastIndex(of: ":") else { continue }
            let port = socket[socket.index(after: colon)...]
            guard !port.isEmpty else { continue }
            if socket.hasPrefix("[") {
                hints.append("[::1]:\(port)")
            } else {
                hints.append("127.0.0.1:\(port)")
            }
        }
        hints.append(contentsOf: await manager.directAddresses())
        var seen = Set<String>()
        return hints.filter { seen.insert($0).inserted }
    }

    struct SupportFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }
}

/// Awaitable one-shot completion used to hand a host-side outcome back to
/// the test body.
actor TestCompletionBox {
    private var outcome: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func complete(with result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        let resumed = waiters
        waiters = []
        for waiter in resumed {
            waiter.resume(with: result)
        }
    }

    func awaitCompletion() async throws {
        if let outcome {
            return try outcome.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// A settable flag with a timestamp, for ordering assertions.
actor TestOrderingFlag {
    private(set) var setAt: ContinuousClock.Instant?

    var isSet: Bool { setAt != nil }

    func set() {
        if setAt == nil {
            setAt = ContinuousClock().now
        }
    }
}

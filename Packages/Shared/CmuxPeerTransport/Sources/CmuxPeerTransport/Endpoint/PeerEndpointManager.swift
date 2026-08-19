public import Foundation
public import CmuxPeerTransportCore
internal import IrohLib

/// ALPN identifiers owned by the endpoint layer. Kept as plain strings here so
/// the Endpoint wave does not depend on in-flux Core protocol files; the value
/// must stay byte-identical to `PeerProtocolConfiguration.cmuxMobileV2.alpn`.
public enum PeerTransportALPN {
    public static let mobileV2 = "cmux/mobile/2"
}

/// One relay entry as the endpoint layer consumes it. Mirrors upstream
/// `RelayConfig(url:quicPort:authToken:)`; `authToken` is the endpoint-bound
/// relay JWT sent as `Authorization: Bearer` on the relay websocket upgrade.
///
/// Defined here so the Endpoint wave does not import the Relay agent's files;
/// unification into one shared type is a follow-up.
public struct PeerRelayEndpointConfig: Sendable, Hashable {
    public let url: String
    public let authToken: String?
    public let quicPort: UInt16?

    public init(url: String, authToken: String? = nil, quicPort: UInt16? = nil) {
        self.url = url
        self.authToken = authToken
        self.quicPort = quicPort
    }
}

/// Home-relay connectivity as last reported by the endpoint's relay watcher.
public struct PeerHomeRelayStatus: Sendable, Equatable {
    /// Relay URLs the endpoint is currently connected to. Empty when the
    /// endpoint is inactive, direct-only, or has not reached a relay yet.
    public let connectedRelayURLs: [String]

    public var isConnected: Bool { !connectedRelayURLs.isEmpty }

    public init(connectedRelayURLs: [String]) {
        self.connectedRelayURLs = connectedRelayURLs
    }
}

public enum PeerEndpointManagerError: Error, Sendable, Equatable {
    /// The secret key was not exactly 32 bytes.
    case invalidSecretKey
    /// An operation that requires a live endpoint ran while none exists.
    case notActivated
    /// The caller's captured runtime generation is no longer current.
    case staleGeneration
    /// A concurrent activate/deactivate/recreate replaced this operation.
    case superseded
    /// `Endpoint.bind` failed; the reason is the FFI error message.
    case activationFailed(String)
    /// A runtime relay insert/remove failed; the reason is the FFI message.
    case relayUpdateFailed(String)
}

/// Owns the process's one iroh `Endpoint` (per design: one endpoint per
/// process, activation barrier, recreate-from-same-key for upstream
/// iroh#4289 driver death).
///
/// All IrohLib types stay inside this module: the public surface speaks
/// `Data`, `String`, and `Peer*` value types only.
public actor PeerEndpointManager {
    /// Awaitable activation barrier. Dial paths await `active` instead of
    /// ever observing "endpoint unavailable".
    public nonisolated let readiness = PeerEndpointReadiness()

    /// Runtime generation counter. Advances on every activate, recreate, and
    /// deactivate so stale continuations fence out. The identity generation
    /// (key/account binding) is owned elsewhere and never changes here.
    nonisolated let runtimeGenerations = PeerGenerationCounter()

    private struct ActivationInputs: Sendable {
        var secretKey: Data
        var relays: [PeerRelayEndpointConfig]
        var directOnly: Bool
    }

    private let alpn: String
    private var endpoint: Endpoint?
    private var inputs: ActivationInputs?
    /// Bumped by every lifecycle entrypoint; awaits inside those entrypoints
    /// revalidate it so an interleaved deactivate/activate wins.
    private var lifecycleEpoch: UInt64 = 0

    public init(alpn: String = PeerTransportALPN.mobileV2) {
        self.alpn = alpn
    }

    // MARK: - Lifecycle

    /// Builds the endpoint from the Minimal preset (crypto provider only — no
    /// n0 relays, no public DNS discovery), applies `RelayMode.custom` with
    /// the given auth-token configs (or `.disabled` when `directOnly` or the
    /// list is empty), and drives the readiness barrier to `.active` with a
    /// new runtime generation. Replaces any previously active endpoint.
    @discardableResult
    public func activate(
        secretKey: Data,
        relays: [PeerRelayEndpointConfig],
        directOnly: Bool
    ) async throws -> PeerTransportGeneration {
        guard secretKey.count == 32 else {
            throw PeerEndpointManagerError.invalidSecretKey
        }
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        await closeCurrentEndpoint()
        guard lifecycleEpoch == epoch else {
            throw PeerEndpointManagerError.superseded
        }
        await readiness.noteActivating()

        let relayMode: RelayMode
        if directOnly || relays.isEmpty {
            relayMode = RelayMode.disabled()
        } else {
            let map = RelayMap.empty()
            for relay in relays {
                do {
                    try map.insert(config: Self.ffiRelayConfig(relay))
                } catch let error as IrohError {
                    await readiness.noteFailed(reason: error.message())
                    throw PeerEndpointManagerError.activationFailed(error.message())
                }
            }
            relayMode = RelayMode.custom(map: map)
        }

        let options = EndpointOptions(
            preset: presetMinimal(),
            secretKey: secretKey,
            alpns: [Data(alpn.utf8)],
            relayMode: relayMode
        )
        let bound: Endpoint
        do {
            bound = try await Endpoint.bind(options: options)
        } catch let error as IrohError {
            await readiness.noteFailed(reason: error.message())
            throw PeerEndpointManagerError.activationFailed(error.message())
        }
        guard lifecycleEpoch == epoch else {
            try? await bound.close()
            throw PeerEndpointManagerError.superseded
        }
        endpoint = bound
        inputs = ActivationInputs(
            secretKey: secretKey, relays: relays, directOnly: directOnly
        )
        let generation = runtimeGenerations.advance()
        await readiness.noteActive(generation: generation)
        return generation
    }

    /// Tears the endpoint down and forgets the activation inputs. The
    /// readiness barrier parks new waiters; the runtime generation advances so
    /// in-flight continuations fence out. Also unblocks any accept loop parked
    /// on the closing endpoint.
    public func deactivate() async {
        lifecycleEpoch &+= 1
        inputs = nil
        await closeCurrentEndpoint()
    }

    /// Rebuilds the endpoint from the same secret and relay set, advancing
    /// the runtime generation only — the endpoint ID is unchanged. This is
    /// the health-watchdog path for upstream iroh#4289 (failed-rebind driver
    /// death).
    @discardableResult
    public func recreate() async throws -> PeerTransportGeneration {
        guard let inputs else {
            throw PeerEndpointManagerError.notActivated
        }
        return try await activate(
            secretKey: inputs.secretKey,
            relays: inputs.relays,
            directOnly: inputs.directOnly
        )
    }

    // MARK: - Relay rotation

    /// Executes rotation steps against the live endpoint: inserts first (so a
    /// refreshed credential is live before its stale twin goes away —
    /// make-before-break), then removes. The stored activation inputs are
    /// updated to match, so a later `recreate()` rebuilds with the rotated
    /// relay set.
    public func applyRelays(
        insert: [PeerRelayEndpointConfig],
        remove: [String]
    ) async throws {
        guard let endpoint else {
            throw PeerEndpointManagerError.notActivated
        }
        let epoch = lifecycleEpoch
        for config in insert {
            do {
                try await endpoint.insertRelay(config: Self.ffiRelayConfig(config))
            } catch let error as IrohError {
                throw PeerEndpointManagerError.relayUpdateFailed(error.message())
            }
            guard lifecycleEpoch == epoch else {
                throw PeerEndpointManagerError.superseded
            }
            recordRelayInsert(config)
        }
        for url in remove {
            do {
                _ = try await endpoint.removeRelay(url: url)
            } catch let error as IrohError {
                throw PeerEndpointManagerError.relayUpdateFailed(error.message())
            }
            guard lifecycleEpoch == epoch else {
                throw PeerEndpointManagerError.superseded
            }
            recordRelayRemove(url)
        }
    }

    /// Current home-relay state, read on demand from the endpoint's
    /// advertised address.
    ///
    /// Upstream note: iroh-ffi v1.1.0's `watchHomeRelay` (like the other sync
    /// `watch*` registrations) calls `tokio::spawn` without entering the FFI
    /// runtime, so invoking it from Swift panics the Rust side ("there is no
    /// reactor running"). Until that is fixed upstream, home-relay status is
    /// a poll-on-demand read of `addr().relayUrl()`, which reports the home
    /// relay once one is selected.
    public func homeRelayStatus() -> PeerHomeRelayStatus {
        guard let endpoint, let url = endpoint.addr().relayUrl() else {
            return PeerHomeRelayStatus(connectedRelayURLs: [])
        }
        return PeerHomeRelayStatus(connectedRelayURLs: [url])
    }

    // MARK: - Introspection

    /// Lowercase hex encoding of the endpoint's 32-byte public key, or nil
    /// when inactive. Stable across `recreate()` (same secret key).
    public var endpointID: String? {
        guard let endpoint else { return nil }
        return PeerHex.encode(endpoint.id().toBytes())
    }

    /// The direct `ip:port` candidates the endpoint currently advertises.
    public func directAddresses() -> [String] {
        guard let endpoint else { return [] }
        return endpoint.addr().directAddresses()
    }

    /// The local socket addresses the endpoint is bound to (wildcard forms
    /// like `0.0.0.0:port`). Useful for loopback dial hints.
    public func boundSocketAddresses() -> [String] {
        guard let endpoint else { return [] }
        return endpoint.boundSockets()
    }

    /// Lightweight liveness verdict for the health watchdog. `.inactive` is
    /// an intentional non-active state (never triggers recreate); `.dead`
    /// means the endpoint died underneath us (iroh#4289 class).
    public func probeHealth() -> PeerEndpointHealthVerdict {
        guard let endpoint else { return .inactive }
        if endpoint.isClosed() {
            return .dead("endpoint closed underneath the manager")
        }
        if endpoint.boundSockets().isEmpty {
            return .dead("endpoint has no bound sockets (rebind failure)")
        }
        return .healthy
    }

    /// True when `generation` is still the current runtime generation.
    /// Continuations call this after every await before touching state.
    public nonisolated func isCurrent(_ generation: PeerTransportGeneration) -> Bool {
        runtimeGenerations.isCurrent(generation)
    }

    // MARK: - Module-internal seams

    /// The live FFI endpoint, fenced by generation. Only the dialer and the
    /// inbound listener (same module) consume this; IrohLib never crosses the
    /// public API.
    func liveEndpoint(expecting generation: PeerTransportGeneration) throws -> Endpoint {
        guard let endpoint else {
            throw PeerEndpointManagerError.notActivated
        }
        guard runtimeGenerations.isCurrent(generation) else {
            throw PeerEndpointManagerError.staleGeneration
        }
        return endpoint
    }

    // MARK: - Private

    private func closeCurrentEndpoint() async {
        await readiness.noteInactive()
        guard let endpoint else { return }
        self.endpoint = nil
        // Fence out continuations captured against the endpoint being closed.
        runtimeGenerations.advance()
        try? await endpoint.close()
    }

    private func recordRelayInsert(_ config: PeerRelayEndpointConfig) {
        guard var current = inputs else { return }
        current.relays.removeAll { $0.url == config.url }
        current.relays.append(config)
        inputs = current
    }

    private func recordRelayRemove(_ url: String) {
        guard var current = inputs else { return }
        current.relays.removeAll { $0.url == url }
        inputs = current
    }

    private static func ffiRelayConfig(_ config: PeerRelayEndpointConfig) -> RelayConfig {
        RelayConfig(
            url: config.url,
            quicPort: config.quicPort,
            authToken: config.authToken
        )
    }
}

/// Hex codec for 32-byte endpoint IDs. Matches upstream `EndpointId`'s own
/// display format (lowercase hex) without relying on it.
enum PeerHex {
    private static let digits: [Character] = Array("0123456789abcdef")

    static func encode(_ data: Data) -> String {
        var out = String()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    static func decode(_ string: String) -> Data? {
        let characters = Array(string.lowercased())
        guard characters.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard
                let high = digits.firstIndex(of: characters[index]),
                let low = digits.firstIndex(of: characters[index + 1])
            else { return nil }
            out.append(UInt8(high << 4 | low))
            index += 2
        }
        return out
    }
}

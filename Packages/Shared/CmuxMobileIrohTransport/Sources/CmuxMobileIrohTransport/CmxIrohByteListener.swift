public import Foundation
import Dispatch
internal import CmuxIrohFFI

/// The Mac host's iroh accept lane (plans/feat-ios-iroh/DESIGN.md PR 4): binds
/// one long-lived endpoint with a persisted secret key and accepts incoming
/// connections, each surfaced as a ``CmxIrohByteStream`` the host drives exactly
/// like the existing `NWConnection` lane. The accept loop, route publication,
/// and Keychain custody in `MobileHostService` wrap this primitive.
///
/// The listener owns its endpoint; accepted streams own only their connection,
/// so closing the listener tears down the accept side without disturbing
/// connections the host is still draining.
public actor CmxIrohByteListener {
    /// The ALPN every cmux mobile-host endpoint speaks. Unused by the FFI today
    /// (the Rust side pins it), kept here as the documented protocol id.
    public static let alpn = "dev.cmux.mobile.terminal/0"

    private let secretKey: [UInt8]?
    private let enableRelay: Bool
    private let relayURL: String?
    private let maximumReceiveLength: Int

    private var endpoint: OpaquePointer?
    private var didClose = false

    private nonisolated let blockingQueue = DispatchQueue(
        label: "dev.cmux.iroh.listener",
        attributes: .concurrent
    )

    /// - Parameters:
    ///   - secretKey: The Mac's 32-byte iroh secret key. When nil a fresh
    ///     ephemeral key is generated on ``start()``; the host supplies a stable
    ///     Keychain key so the Mac keeps one EndpointId across launches.
    ///   - enableRelay: Whether the endpoint enables relays/discovery.
    ///     Defaults to true; tests pass false for hermetic loopback.
    ///   - relayURL: When set (and `enableRelay` is true), the endpoint homes on
    ///     this custom relay (the user's own `iroh-relay`) instead of the default
    ///     n0 fleet. nil/empty keeps the default fleet (cmux-hosted iroh).
    public init(
        secretKey: [UInt8]? = nil,
        enableRelay: Bool = true,
        relayURL: String? = nil,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength
    ) {
        self.secretKey = secretKey
        self.enableRelay = enableRelay
        self.relayURL = relayURL
        self.maximumReceiveLength = maximumReceiveLength
    }

    /// Binds the accept endpoint. Idempotent: a second call is a no-op.
    public func start() async throws {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        if endpoint != nil { return }

        let key: [UInt8]
        if let secretKey {
            guard secretKey.count == CmxIrohByteTransport.secretKeyLength else {
                throw CmxIrohByteTransportError.invalidSecretKey
            }
            key = secretKey
        } else {
            guard let generated = CmxIrohByteTransport.generateSecretKey() else {
                throw CmxIrohByteTransportError.keyGenerationFailed
            }
            key = generated
        }
        let relayEnabled = enableRelay
        let relay = relayURL

        let result = await runBlocking { () -> Result<CmxIrohUnsafeBox<OpaquePointer>, CmxIrohByteTransportError> in
            let bind = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                CmxIrohByteTransport.withOptionalCString(relay) { relayC in
                    key.withUnsafeBufferPointer { keyBuffer in
                        cmux_iroh_endpoint_bind(
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            relayEnabled,
                            relayC,
                            true,
                            kindPtr,
                            errBuf,
                            cap
                        )
                    }
                }
            }
            guard let endpoint = bind.result else {
                return .failure(.bindFailed(bind.message))
            }
            return .success(CmxIrohUnsafeBox(endpoint))
        }

        switch result {
        case let .success(box):
            endpoint = box.value
        case let .failure(error):
            throw error
        }
    }

    /// The bound endpoint's EndpointId, or nil before ``start()``.
    public var endpointID: String? {
        guard let endpoint else { return nil }
        return CmxIrohByteTransport.takeString(cmux_iroh_endpoint_id(endpoint))
    }

    /// A `CmxAttachRoute`-shaped JSON description (id, direct addrs, relay URL)
    /// the host publishes into attach tickets, QR payloads, and the registry.
    public func routeJSON() -> String? {
        guard let endpoint else { return nil }
        return CmxIrohByteTransport.takeString(cmux_iroh_endpoint_route_json(endpoint))
    }

    /// Accepts one incoming connection and its first bidirectional stream.
    /// `timeoutMilliseconds == 0` blocks until a connection arrives or the
    /// listener is closed (which throws ``CmxIrohByteTransportError/acceptFailed``).
    public func accept(timeoutMilliseconds: UInt64 = 0) async throws -> CmxIrohByteStream {
        if didClose { throw CmxIrohByteTransportError.alreadyClosed }
        guard let endpoint else { throw CmxIrohByteTransportError.notStarted }
        let endpointBox = CmxIrohUnsafeBox(endpoint)
        let capacity = maximumReceiveLength

        let outcome = await runBlocking { () -> CmxIrohCallOutcome<CmxIrohUnsafeBox<OpaquePointer>?> in
            let accept = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                cmux_iroh_endpoint_accept(endpointBox.value, timeoutMilliseconds, kindPtr, errBuf, cap)
            }
            return CmxIrohCallOutcome(
                result: accept.result.map(CmxIrohUnsafeBox.init),
                errorKind: accept.errorKind,
                message: accept.message
            )
        }

        guard let connectionBox = outcome.result else {
            throw CmxIrohByteTransportError.acceptFailed(
                outcome.message,
                CmxIrohConnectFailureKind(rawKind: outcome.errorKind)
            )
        }
        return CmxIrohByteStream(
            connection: connectionBox.value,
            maximumReceiveLength: capacity
        )
    }

    /// Closes the endpoint, waking any blocked ``accept()``. Idempotent.
    public func close() async {
        if didClose { return }
        didClose = true
        let endpointBox = endpoint.map(CmxIrohUnsafeBox.init)
        endpoint = nil
        _ = await runBlocking { () -> Bool in
            if let endpointBox {
                cmux_iroh_endpoint_close(endpointBox.value)
            }
            return true
        }
    }

    private nonisolated func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            blockingQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

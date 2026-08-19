internal import Foundation
internal import IrohLib

/// Which transport class currently carries this connection's data.
public enum PeerRouteClass: String, Sendable {
    case direct
    case relay
    case unknown
}

/// One open network path, for route-class diagnostics.
public struct PeerPathDiagnostic: Sendable, Equatable {
    public let remoteAddress: String
    public let isRelay: Bool
    public let isSelected: Bool
    public let rttMilliseconds: UInt64

    public init(
        remoteAddress: String,
        isRelay: Bool,
        isSelected: Bool,
        rttMilliseconds: UInt64
    ) {
        self.remoteAddress = remoteAddress
        self.isRelay = isRelay
        self.isSelected = isSelected
        self.rttMilliseconds = rttMilliseconds
    }
}

/// Snapshot of the connection's paths and selected route class.
public struct PeerConnectionRouteDiagnostics: Sendable, Equatable {
    public let routeClass: PeerRouteClass
    public let paths: [PeerPathDiagnostic]
    /// RTT of the selected path in milliseconds, when one is selected.
    public let rttMilliseconds: UInt64?

    public init(
        routeClass: PeerRouteClass,
        paths: [PeerPathDiagnostic],
        rttMilliseconds: UInt64?
    ) {
        self.routeClass = routeClass
        self.paths = paths
        self.rttMilliseconds = rttMilliseconds
    }
}

/// Headline transport counters, passed through for telemetry.
public struct PeerConnectionStatistics: Sendable, Equatable {
    public let udpTransmittedDatagrams: Int64
    public let udpTransmittedBytes: Int64
    public let udpReceivedDatagrams: Int64
    public let udpReceivedBytes: Int64
    public let lostPackets: Int64
    public let lostBytes: Int64

    public init(
        udpTransmittedDatagrams: Int64,
        udpTransmittedBytes: Int64,
        udpReceivedDatagrams: Int64,
        udpReceivedBytes: Int64,
        lostPackets: Int64,
        lostBytes: Int64
    ) {
        self.udpTransmittedDatagrams = udpTransmittedDatagrams
        self.udpTransmittedBytes = udpTransmittedBytes
        self.udpReceivedDatagrams = udpReceivedDatagrams
        self.udpReceivedBytes = udpReceivedBytes
        self.lostPackets = lostPackets
        self.lostBytes = lostBytes
    }
}

/// An active QUIC connection to a remote endpoint.
///
/// Sendable invariant: `Connection` is a UniFFI handle to a thread-safe Rust
/// object (all methods synchronize internally); IrohLib declares it
/// `@unchecked Sendable`. This wrapper holds it immutably and adds no mutable
/// state, so plain `Sendable` conformance is sound. The wrapped handle never
/// crosses the module's public API.
public final class PeerQuicConnection: Sendable {
    private let connection: Connection

    init(wrapping connection: Connection) {
        self.connection = connection
    }

    /// Lowercase hex encoding of the remote peer's 32-byte endpoint ID.
    public var remoteEndpointID: String {
        PeerHex.encode(connection.remoteId().toBytes())
    }

    // MARK: - Streams

    /// Opens an outgoing bidirectional stream.
    public func openBi() async throws -> PeerByteStream {
        do {
            let stream = try await connection.openBi()
            return PeerByteStream(
                send: stream.send(), recv: stream.recv(), direction: .bidirectional
            )
        } catch {
            throw PeerStreamError.wrap(error, operation: "openBi")
        }
    }

    /// Opens an outgoing unidirectional (write-only) stream.
    public func openUni() async throws -> PeerByteStream {
        do {
            let send = try await connection.openUni()
            return PeerByteStream(send: send, recv: nil, direction: .outboundOnly)
        } catch {
            throw PeerStreamError.wrap(error, operation: "openUni")
        }
    }

    /// Accepts the next incoming bidirectional stream.
    public func acceptBi() async throws -> PeerByteStream {
        do {
            let stream = try await connection.acceptBi()
            return PeerByteStream(
                send: stream.send(), recv: stream.recv(), direction: .bidirectional
            )
        } catch {
            throw PeerStreamError.wrap(error, operation: "acceptBi")
        }
    }

    /// Accepts the next incoming unidirectional (read-only) stream.
    public func acceptUni() async throws -> PeerByteStream {
        do {
            let recv = try await connection.acceptUni()
            return PeerByteStream(send: nil, recv: recv, direction: .inboundOnly)
        } catch {
            throw PeerStreamError.wrap(error, operation: "acceptUni")
        }
    }

    // MARK: - Lifecycle

    /// Closes the connection immediately with an application reason.
    /// Best-effort and idempotent.
    public func close(reason: String) {
        try? connection.close(errorCode: 0, reason: Data(reason.utf8))
    }

    /// Resolves when the connection is closed, returning the cause.
    public func awaitClosed() async -> String {
        await connection.closed()
    }

    /// If the connection is already closed, the reason; nil while open.
    public var closeReason: String? {
        connection.closeReason()
    }

    // MARK: - Diagnostics

    /// RTT estimate of the selected path in milliseconds, if any.
    public var rttMilliseconds: UInt64? {
        connection.rtt()
    }

    /// Snapshot of open paths and the selected route class (direct vs relay).
    public func routeDiagnostics() -> PeerConnectionRouteDiagnostics {
        let paths = connection.paths().map { path in
            PeerPathDiagnostic(
                remoteAddress: path.remoteAddr,
                isRelay: path.isRelay,
                isSelected: path.isSelected,
                rttMilliseconds: path.rttMs
            )
        }
        let selected = paths.first { $0.isSelected }
        let routeClass: PeerRouteClass
        if let selected {
            routeClass = selected.isRelay ? .relay : .direct
        } else {
            routeClass = .unknown
        }
        return PeerConnectionRouteDiagnostics(
            routeClass: routeClass,
            paths: paths,
            rttMilliseconds: selected?.rttMilliseconds ?? connection.rtt()
        )
    }

    /// Headline transport counters.
    public func statistics() -> PeerConnectionStatistics {
        let stats = connection.stats()
        return PeerConnectionStatistics(
            udpTransmittedDatagrams: stats.udpTxDatagrams,
            udpTransmittedBytes: stats.udpTxBytes,
            udpReceivedDatagrams: stats.udpRxDatagrams,
            udpReceivedBytes: stats.udpRxBytes,
            lostPackets: stats.lostPackets,
            lostBytes: stats.lostBytes
        )
    }
}

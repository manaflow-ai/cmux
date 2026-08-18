public import Foundation
internal import IrohLib

/// Failure surfaced by stream and stream-open operations. IrohLib errors are
/// mapped into this type so nothing FFI-typed crosses the module boundary.
/// `CancellationError` is never converted.
public struct PeerStreamError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Read on a stream with no receive half (outbound unidirectional).
        case notReadable
        /// Write/finish on a stream with no send half (inbound unidirectional).
        case notWritable
        /// The stream or its connection is already closed.
        case closed
        /// Any other I/O failure.
        case io
    }

    public let kind: Kind
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public var description: String { "PeerStreamError(\(kind): \(reason))" }

    /// Maps an FFI error into `PeerStreamError`, passing `CancellationError`
    /// (and already-mapped errors) through untouched.
    static func wrap(_ error: any Error, operation: String) -> any Error {
        if error is CancellationError { return error }
        if let mapped = error as? PeerStreamError { return mapped }
        if let iroh = error as? IrohError {
            let kind: Kind = iroh.isKind(kind: .closed) ? .closed : .io
            return PeerStreamError(kind: kind, reason: "\(operation): \(iroh.message())")
        }
        return PeerStreamError(kind: .io, reason: "\(operation): \(String(describing: error))")
    }
}

/// A QUIC byte stream (one or both halves).
///
/// Sendable invariant: `SendStream`/`RecvStream` are UniFFI handles to Rust
/// objects that lock internally (`Arc<Mutex<_>>`); IrohLib declares them
/// `@unchecked Sendable`. This wrapper holds them immutably and adds no
/// mutable state, so plain `Sendable` conformance is sound.
public final class PeerByteStream: Sendable {
    public enum Direction: Sendable, Equatable {
        case bidirectional
        /// Locally opened unidirectional stream: write-only.
        case outboundOnly
        /// Remotely opened unidirectional stream: read-only.
        case inboundOnly
    }

    /// Upper bound for a single buffered read. Larger requests are clamped.
    public static let maxReadChunkBytes = 1 << 20

    public let direction: Direction
    private let sendHalf: SendStream?
    private let recvHalf: RecvStream?

    init(send: SendStream?, recv: RecvStream?, direction: Direction) {
        self.sendHalf = send
        self.recvHalf = recv
        self.direction = direction
    }

    // MARK: - Reading

    /// Reads up to `maxLength` bytes (clamped to `maxReadChunkBytes`).
    /// Returns nil at end of stream.
    public func read(maxLength: Int = 1 << 16) async throws -> Data? {
        let recv = try requireReadable(operation: "read")
        let bounded = UInt32(clamping: min(max(1, maxLength), Self.maxReadChunkBytes))
        do {
            let data = try await recv.read(sizeLimit: bounded)
            return data.isEmpty ? nil : data
        } catch {
            throw PeerStreamError.wrap(error, operation: "read")
        }
    }

    /// Reads until end of stream, failing if more than `maxLength` bytes
    /// arrive (bounded buffer — a hostile peer cannot balloon memory).
    public func readToEnd(maxLength: Int = PeerByteStream.maxReadChunkBytes) async throws -> Data {
        let recv = try requireReadable(operation: "readToEnd")
        let bounded = UInt32(clamping: min(max(1, maxLength), Self.maxReadChunkBytes))
        do {
            return try await recv.readToEnd(sizeLimit: bounded)
        } catch {
            throw PeerStreamError.wrap(error, operation: "readToEnd")
        }
    }

    /// Reads exactly `count` bytes, erroring if the stream ends early.
    public func readExact(count: Int) async throws -> Data {
        let recv = try requireReadable(operation: "readExact")
        guard count > 0, count <= Self.maxReadChunkBytes else {
            throw PeerStreamError(
                kind: .io,
                reason: "readExact count \(count) outside 1...\(Self.maxReadChunkBytes)"
            )
        }
        do {
            return try await recv.readExact(size: UInt32(count))
        } catch {
            throw PeerStreamError.wrap(error, operation: "readExact")
        }
    }

    // MARK: - Writing

    /// Writes all bytes, looping as needed.
    public func write(_ data: Data) async throws {
        let send = try requireWritable(operation: "write")
        do {
            try await send.writeAll(buf: data)
        } catch {
            throw PeerStreamError.wrap(error, operation: "write")
        }
    }

    /// Signals that no more data will be sent (FIN).
    public func finish() async throws {
        let send = try requireWritable(operation: "finish")
        do {
            try await send.finish()
        } catch {
            throw PeerStreamError.wrap(error, operation: "finish")
        }
    }

    /// Abandons the stream: aborts the send half and stops the receive half.
    /// Best-effort and idempotent.
    public func reset(errorCode: UInt64 = 0) async {
        if let sendHalf {
            try? await sendHalf.reset(errorCode: errorCode)
        }
        if let recvHalf {
            try? await recvHalf.stop(errorCode: errorCode)
        }
    }

    // MARK: - Private

    private func requireReadable(operation: String) throws -> RecvStream {
        guard let recvHalf else {
            throw PeerStreamError(
                kind: .notReadable,
                reason: "\(operation) on a write-only stream (\(direction))"
            )
        }
        return recvHalf
    }

    private func requireWritable(operation: String) throws -> SendStream {
        guard let sendHalf else {
            throw PeerStreamError(
                kind: .notWritable,
                reason: "\(operation) on a read-only stream (\(direction))"
            )
        }
        return sendHalf
    }
}

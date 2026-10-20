import Foundation

/// One end of a tunneled TCP connection: the browser's socket on the phone,
/// or the exit (an SSH channel, a paired Mac's lane, a direct socket).
///
/// Every call suspends until done. The relay reads one chunk and writes it
/// before reading the next, so memory per connection is bounded by one chunk
/// per direction and a slow side backpressures the other.
public protocol TunnelByteStream: AnyObject, Sendable {
    /// The next chunk, or nil once the other end finished sending.
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    /// Half-close: no more bytes from this side.
    func finishWriting() async
    /// Aborts both directions. Idempotent; a pending `read` returns.
    func close() async
}

/// Why an exit could not open a connection, in SOCKS5 reply terms
/// (RFC 1928 section 6).
public enum TunnelOpenError: Error, Equatable, Sendable {
    /// The exit's policy refused the destination.
    case notAllowed
    case connectionRefused
    case hostUnreachable
    case networkUnreachable
    case timedOut
    /// The exit is not reachable right now (disconnected, busy).
    case unavailable
    case generalFailure

    public var socksReply: SocksReply {
        switch self {
        case .notAllowed: .notAllowed
        case .connectionRefused: .connectionRefused
        case .hostUnreachable: .hostUnreachable
        case .networkUnreachable: .networkUnreachable
        case .timedOut: .ttlExpired
        case .unavailable, .generalFailure: .generalFailure
        }
    }
}

/// Opens connections at the exit point: every accepted SOCKS `CONNECT` and
/// every loopback forward goes through one of these.
public protocol SocksConnectBackend: Sendable {
    /// Connects to `host:port` as seen from the exit. Returns once the exit
    /// has confirmed the connection, so a refused connect never looks open.
    /// Throws `TunnelOpenError` (other errors count as `.generalFailure`).
    func open(host: String, port: Int) async throws -> any TunnelByteStream
}

/// Copies bytes between two streams until both directions finish.
public struct TunnelRelay: Sendable {
    private let first: any TunnelByteStream
    private let second: any TunnelByteStream

    /// Pairs two ends of one tunneled connection.
    public init(_ first: any TunnelByteStream, _ second: any TunnelByteStream) {
        self.first = first
        self.second = second
    }

    /// Runs until both sides have finished (half-closes pass through in
    /// each direction) or either fails, in which case both are aborted.
    /// Cancelling the calling task aborts both. Returns whether both
    /// directions ended cleanly.
    @discardableResult
    public func run() async -> Bool {
        let first = first
        let second = second
        return await withTaskCancellationHandler {
            let clean = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask { await Self.pump(from: first, to: second) }
                group.addTask { await Self.pump(from: second, to: first) }
                var clean = true
                for await directionClean in group where !directionClean && clean {
                    clean = false
                    await first.close()
                    await second.close()
                }
                return clean
            }
            await first.close()
            await second.close()
            return clean
        } onCancel: {
            Task {
                await first.close()
                await second.close()
            }
        }
    }

    private static func pump(from source: any TunnelByteStream, to sink: any TunnelByteStream) async -> Bool {
        do {
            while let chunk = try await source.read() {
                try Task.checkCancellation()
                if !chunk.isEmpty { try await sink.write(chunk) }
            }
            await sink.finishWriting()
            return true
        } catch {
            return false
        }
    }
}

/// Maps an arbitrary backend error to a SOCKS reply.
extension SocksReply {
    static func forOpenFailure(_ error: any Error) -> SocksReply {
        (error as? TunnelOpenError)?.socksReply ?? .generalFailure
    }
}

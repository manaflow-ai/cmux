import Foundation
import Network

/// An `NWConnection`-backed RFB transport. Conforms to both ``RFBByteSource``
/// and ``RFBByteSink``; the connection's own serial queue plus this actor's
/// isolation guarantee that whole messages are read and written atomically and
/// never interleave.
public actor NWConnectionTransport: RFBByteSource, RFBByteSink {
    private let connection: NWConnection
    private var inboundBuffer: [UInt8] = []
    private var didStart = false

    public init(host: String, port: UInt16) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .vnc
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // latency over throughput: don't coalesce input events
        self.connection = NWConnection(host: endpointHost, port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Opens the TCP connection, returning when it is `.ready`.
    public func connect() async throws {
        guard !didStart else { return }
        didStart = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.tryResume() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.tryResume() { continuation.resume(throwing: RFBError.transport(error.localizedDescription)) }
                case .cancelled:
                    if resumed.tryResume() { continuation.resume(throwing: RFBError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        connection.stateUpdateHandler = nil
    }

    public func close() {
        connection.cancel()
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func readExactly(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        while inboundBuffer.count < count {
            let chunk = try await receiveChunk()
            inboundBuffer.append(contentsOf: chunk)
        }
        let result = Array(inboundBuffer.prefix(count))
        inboundBuffer.removeFirst(count)
        return result
    }

    private func receiveChunk() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                    return
                }
                if isComplete {
                    continuation.resume(throwing: RFBError.connectionClosed)
                    return
                }
                // No bytes yet and not complete: return empty so the caller loops.
                continuation.resume(returning: [])
            }
        }
    }
}

/// Guards a continuation against being resumed more than once from
/// `stateUpdateHandler`, which can fire repeatedly.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

private extension NWEndpoint.Port {
    static let vnc = NWEndpoint.Port(rawValue: 5900)!
}

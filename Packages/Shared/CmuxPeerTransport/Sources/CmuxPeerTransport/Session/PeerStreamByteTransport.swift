public import CMUXMobileCore
public import Foundation

/// `CmxByteTransport` over one already-open QUIC stream, so the existing RPC
/// serving and session layers (`MobileHostConnection`,
/// `MobileCoreRPCSession`) run unchanged on the new transport.
///
/// `initialBytes` carries application bytes that arrived in the same reads as
/// the lane header or admission ack; they are returned by the first
/// `receive()` calls before any further stream reads.
public final class PeerStreamByteTransport: CmxByteTransport, @unchecked Sendable {
    private static let identityCounter = PeerGenerationCounterBox()

    private let stream: PeerByteStream
    private let awaitConnectionClosed: @Sendable () async -> Void
    private let identity: UInt64
    private let lock = NSLock()
    private var pendingInitialBytes: Data
    private var isClosed = false

    public init(
        stream: PeerByteStream,
        initialBytes: Data = Data(),
        awaitConnectionClosed: @escaping @Sendable () async -> Void
    ) {
        self.stream = stream
        self.pendingInitialBytes = initialBytes
        self.awaitConnectionClosed = awaitConnectionClosed
        self.identity = Self.identityCounter.next()
    }

    public func connect() async throws {
        // The stream is open by construction; admission already happened.
    }

    public func receive() async throws -> Data? {
        enum Buffered {
            case initialBytes(Data)
            case closed
            case readFromStream
        }
        let state: Buffered = lock.withLock {
            if !pendingInitialBytes.isEmpty {
                let buffered = pendingInitialBytes
                pendingInitialBytes = Data()
                return .initialBytes(buffered)
            }
            return isClosed ? .closed : .readFromStream
        }
        switch state {
        case .initialBytes(let buffered):
            return buffered
        case .closed:
            return nil
        case .readFromStream:
            return try await stream.read()
        }
    }

    public func send(_ data: Data) async throws {
        let closed = lock.withLock { isClosed }
        if closed {
            throw PeerStreamError(kind: .closed, reason: "transport closed")
        }
        try await stream.write(data)
    }

    public func close() async {
        let alreadyClosed = lock.withLock {
            let previous = isClosed
            isClosed = true
            return previous
        }
        guard !alreadyClosed else { return }
        try? await stream.finish()
        await stream.reset()
    }
}

extension PeerStreamByteTransport: CmxByteTransportClosureObserving {
    public func transportClosureObservation() async -> CmxTransportClosureObservation? {
        let awaitClosed = awaitConnectionClosed
        return CmxTransportClosureObservation {
            await awaitClosed()
        }
    }
}

extension PeerStreamByteTransport: CmxByteTransportContinuityIdentifying {
    public func transportContinuityID() async -> UInt64? {
        lock.withLock { isClosed ? nil : identity }
    }
}

/// Process-local monotonic counter for transport continuity identities.
final class PeerGenerationCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

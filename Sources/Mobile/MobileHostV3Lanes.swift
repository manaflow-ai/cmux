import CMUXMobileCore
import CmuxIrohTransport
import CmuxV3Native
import Foundation

/// Adapts native v3 byte streams to the transport-neutral lane handlers. The
/// adapter deliberately keeps the native peer out of codecs and business code.
enum MobileHostV3ByteStream {

    static func make(stream: NativeStream) -> CmxIrohBidirectionalStream {
        CmxIrohBidirectionalStream(
            receiveStream: MobileHostV3ReceiveStream(stream: stream),
            sendStream: MobileHostV3SendStream(stream: stream)
        )
    }
}

private actor MobileHostV3ReceiveStream: CmxIrohReceiveStream {
    let stream: NativeStream
    private var buffered = Data()
    private var stopped = false

    init(stream: NativeStream) { self.stream = stream }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard !stopped else { return nil }
        let limit = max(1, maximumByteCount)
        while buffered.isEmpty {
            guard let data = try await stream.receive(operation: CmuxV3Native.Operation()) else {
                stopped = true
                return nil
            }
            if !data.isEmpty { buffered.append(data) }
        }
        let count = min(limit, buffered.count)
        let result = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return result
    }

    func stop(errorCode: UInt64) async {
        stopped = true
        buffered.removeAll()
        stream.stopReceive()
    }
}

private final class MobileHostV3SendStream: CmxIrohSendStream, @unchecked Sendable {
    let stream: NativeStream
    init(stream: NativeStream) { self.stream = stream }

    func send(_ data: Data) async throws {
        try await stream.sendAcknowledged(data: data, operation: CmuxV3Native.Operation())
    }

    func finish() async throws {
        try await stream.finishSend(operation: CmuxV3Native.Operation())
    }

    func reset(errorCode: UInt64) async {
        stream.close()
    }

    func setPriority(_: Int32) async throws {}
}

/// Per-peer v3 lane quota and ownership. It is intentionally independent of
/// the v3 connection registry so a reconnect cannot inherit old lane state.
actor MobileHostV3LaneRegistry {
    private static let maximumTerminalLanes = 4
    private static let maximumArtifactLanes = 1
    private static let maximumSimulatorLanes = 2
    private var active: [String: Set<UUID>] = [:]

    enum Kind: Hashable, Sendable { case terminal, artifact, simulator }

    func reserve(peerID: String, kind: Kind) -> UUID? {
        let key = "\(peerID):\(kind)"
        let set = active[key, default: []]
        let limit: Int = switch kind {
        case .terminal: Self.maximumTerminalLanes
        case .artifact: Self.maximumArtifactLanes
        case .simulator: Self.maximumSimulatorLanes
        }
        guard set.count < limit else { return nil }
        let id = UUID()
        active[key, default: []].insert(id)
        return id
    }

    func release(peerID: String, kind: Kind, id: UUID) {
        let key = "\(peerID):\(kind)"
        active[key]?.remove(id)
        if active[key]?.isEmpty == true { active[key] = nil }
    }

    func removeAll() { active.removeAll() }
}

enum MobileHostV3LaneError: Error, Equatable, Sendable {
    case receiveLimitExceeded
}

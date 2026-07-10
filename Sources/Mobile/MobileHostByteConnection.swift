import Foundation
@preconcurrency import Network

/// A connection-lifecycle event from a ``MobileHostByteConnection``, the
/// transport-agnostic subset of `NWConnection.State` the mobile host cares about.
enum MobileHostByteConnectionEvent: Sendable {
    case ready
    case failed(reason: String)
    case cancelled
}

/// The server-side byte channel a ``MobileHostConnection`` drives, mirroring the
/// client's `CmxByteTransport` (plans/feat-ios-iroh/DESIGN.md PR 4). Extracting
/// this lets the same frame codec, RPC dispatch, timeouts, and subscription
/// bookkeeping run unchanged over either a Network.framework TCP connection
/// (today) or an iroh QUIC stream (the iroh accept lane). `receive` is one-shot
/// to match `NWConnection`: after processing each delivery the consumer calls
/// ``resumeReceiving()`` for the next chunk.
protocol MobileHostByteConnection: Sendable {
    func start(
        onEvent: @escaping @Sendable (MobileHostByteConnectionEvent) -> Void,
        onReceive: @escaping @Sendable (Data?, Bool, String?) -> Void
    )
    func resumeReceiving()
    /// Sends a frame, returning nil on success or an error description on failure.
    func send(_ data: Data) async -> String?
    func close()
}

/// The Network.framework adapter: a verbatim wrapper around the calls
/// `MobileHostConnection` made directly before the seam was extracted, so the
/// TCP lane's behavior is unchanged.
// Wraps NWConnection; mutable receive callback storage is guarded by receiveLock.
final class NWMobileHostByteConnection: MobileHostByteConnection, @unchecked Sendable {
    private static let receiveMaximumLength = 64 * 1024

    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let receiveLock = NSLock()
    private var onReceive: (@Sendable (Data?, Bool, String?) -> Void)?

    init(connection: NWConnection, callbackQueue: DispatchQueue) {
        self.connection = connection
        self.callbackQueue = callbackQueue
    }

    func start(
        onEvent: @escaping @Sendable (MobileHostByteConnectionEvent) -> Void,
        onReceive: @escaping @Sendable (Data?, Bool, String?) -> Void
    ) {
        receiveLock.lock()
        self.onReceive = onReceive
        receiveLock.unlock()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                onEvent(.failed(reason: String(describing: error)))
            case .cancelled:
                onEvent(.cancelled)
            case .ready:
                onEvent(.ready)
            case .setup, .waiting, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: callbackQueue)
        receiveOnce()
    }

    func resumeReceiving() {
        receiveOnce()
    }

    private func receiveOnce() {
        receiveLock.lock()
        let deliver = onReceive
        receiveLock.unlock()
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveMaximumLength
        ) { data, _, isComplete, error in
            deliver?(data, isComplete, error.map { String(describing: $0) })
        }
    }

    func send(_ data: Data) async -> String? {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error.map { String(describing: $0) })
                }
            )
        }
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

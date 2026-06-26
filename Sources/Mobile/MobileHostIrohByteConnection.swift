import CmuxMobileIrohTransport
import Foundation

/// The iroh adapter for the Mac host accept lane (plans/feat-ios-iroh/DESIGN.md
/// PR 4): bridges an accepted ``CmxIrohByteStream`` to the callback-based
/// ``MobileHostByteConnection`` the ``MobileHostConnection`` actor drives, so a
/// QUIC stream flows through the exact same frame-codec/RPC path as a TCP
/// connection.
///
/// An accepted iroh stream is already connected, so ``start(onEvent:onReceive:)``
/// emits `.ready` immediately. `CmxIrohByteStream.receive()` is async and
/// returns nil at a clean end of stream; this adapter maps a chunk to
/// `onReceive(data, isComplete: false, nil)`, a nil to
/// `onReceive(nil, isComplete: true, nil)`, and a throw to
/// `onReceive(nil, false, errorDescription)`, matching the `NWConnection`
/// adapter's one-shot delivery contract.
final class MobileHostIrohByteConnection: MobileHostByteConnection, @unchecked Sendable {
    private let stream: CmxIrohByteStream
    private let lock = NSLock()
    private var onReceive: (@Sendable (Data?, Bool, String?) -> Void)?

    init(stream: CmxIrohByteStream) {
        self.stream = stream
    }

    func start(
        onEvent: @escaping @Sendable (MobileHostByteConnectionEvent) -> Void,
        onReceive: @escaping @Sendable (Data?, Bool, String?) -> Void
    ) {
        lock.lock()
        self.onReceive = onReceive
        lock.unlock()
        onEvent(.ready)
        readNext()
    }

    func resumeReceiving() {
        readNext()
    }

    private func readNext() {
        lock.lock()
        let deliver = onReceive
        lock.unlock()
        let stream = self.stream
        Task {
            do {
                if let data = try await stream.receive() {
                    deliver?(data, false, nil)
                } else {
                    deliver?(nil, true, nil)
                }
            } catch {
                deliver?(nil, false, String(describing: error))
            }
        }
    }

    func send(_ data: Data) async -> String? {
        do {
            try await stream.send(data)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func close() {
        let stream = self.stream
        Task { await stream.close() }
    }
}

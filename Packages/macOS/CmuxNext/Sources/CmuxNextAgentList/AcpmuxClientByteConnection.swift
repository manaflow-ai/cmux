public import Foundation
import CmuxNextAgentActivity

/// Drives an `AcpmuxClient` over the existing serial socket connection. It
/// pauses consumption at one undelivered 1 MiB batch and resumes only after
/// the consumer acknowledges that batch; bytes are never dropped.
/// All mutable state is confined to the private utility queue.
public nonisolated final class AcpmuxClientByteConnection: @unchecked Sendable { // crash-allow: callbacks hop back to this serial queue before touching state
    public static let maxUndeliveredBytes = 1 << 20
    private let client: AcpmuxClient
    private let queue = DispatchQueue(label: "cmux.acpmux-client.driver", qos: .utility) // qos-allow: socket bytes are background transport work
    private var input = Data()
    private var pending = Data()
    private var deferredChange: Data?
    private var pendingDelivery = false
    private var deliveredPrefixCount = 0
    private var connection: AgentActivityLineConnection?
    private var onChange: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false

    public init(client: AcpmuxClient) { self.client = client }

    /// Feeds a received chunk through the same serial path used by the socket.
    /// Tests use this to replay recorded daemon bytes without making the test
    /// depend on a daemon process; production callers use `start(path:)`.
    internal func feedForTesting(_ bytes: Data) {
        queue.async { [self] in receive(bytes) }
    }

    internal func beginForTesting(onChange: @escaping @Sendable (Data) -> Void,
                                  onClose: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            self.onChange = onChange
            self.onClose = onClose
        }
    }

    /// Waits until all previously queued test input has run on the driver queue.
    /// Production callers use socket callbacks instead of this synchronization seam.
    internal func flushForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    public func start(path: String, onChange: @escaping @Sendable (Data) -> Void,
                      onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            self.onChange = onChange
            self.onClose = onClose
            let connection = AgentActivityLineConnection(path: path)
            self.connection = connection
            guard client.connected() == 0 else {
                fail()
                return
            }
            var upgrade = Data()
            while let bytes = client.takeSend() { upgrade.append(bytes) }
            connection.startBytes(send: upgrade, onBytes: { [weak self] bytes in
                self?.queue.async { self?.receive(bytes) }
            }, onClose: { [weak self] in
                self?.queue.async {
                    guard let self, !self.closed else { return }
                    self.closed = true
                    self.client.setSendHandler(nil)
                    _ = self.client.disconnected()
                    self.onClose = nil
                    onClose()
                }
            })
            client.setSendHandler { [weak connection] bytes in connection?.send(bytes) }
        }
    }

    public func acknowledgeBatch() {
        queue.async { [self] in
            if deliveredPrefixCount > 0 {
                let count = min(deliveredPrefixCount, pending.count)
                pending.removeSubrange(pending.startIndex..<pending.index(pending.startIndex, offsetBy: count))
            }
            deliveredPrefixCount = 0
            pendingDelivery = false
            processInput()
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            client.setSendHandler(nil)
            _ = client.disconnected()
            connection?.cancel()
            connection = nil
            input.removeAll()
            pending.removeAll()
            deferredChange = nil
            deliveredPrefixCount = 0
            onChange = nil
            onClose = nil
        }
    }

    /// Transfers a v2 fallback's socket to the existing v1 line consumer.
    /// Bytes not consumed by v2 are delivered first and the socket remains open.
    public func handBackToLines(onLine: @escaping @Sendable (Data) -> Void,
                                onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !closed, let connection else { return }
            var prefix = Data()
            if !pending.isEmpty {
                prefix.append(pending)
                prefix.append(0x0A)
            }
            if let deferredChange {
                prefix.append(deferredChange)
                prefix.append(0x0A)
                self.deferredChange = nil
            }
            if !input.isEmpty {
                if !prefix.isEmpty, prefix.last != 0x0A { prefix.append(0x0A) }
                prefix.append(input)
            }
            input.removeAll()
            pending.removeAll(keepingCapacity: true)
            deliveredPrefixCount = 0
            pendingDelivery = false
            closed = true
            client.setSendHandler(nil)
            _ = client.disconnected()
            self.connection = nil
            self.onChange = nil
            self.onClose = nil
            connection.handBackToLines(prefix: prefix, onLine: onLine, onClose: onClose)
        }
    }

    private func receive(_ bytes: Data) {
        guard !closed else { return }
        input.append(bytes)
        processInput()
    }

    private func processInput() {
        guard !closed else { return }
        drainChanges()
        while !input.isEmpty, pending.count < Self.maxUndeliveredBytes {
            let result = client.received(input)
            guard result.isSuccess else {
                fail()
                return
            }
            let consumed = result.consumed
            if consumed > 0 {
                input.removeSubrange(input.startIndex..<input.index(input.startIndex, offsetBy: min(consumed, input.count)))
            }
            drainChanges()
            if consumed == 0 { break }
        }
        drainChanges()
        // The raw connection is suspended for this chunk; keep it suspended while
        // either unread input or one undelivered <=1 MiB batch remains.
        if pending.isEmpty, input.isEmpty {
            connection?.resumeBytes()
        } else {
            drain()
        }
    }

    private func drainChanges() {
        while pending.count < Self.maxUndeliveredBytes {
            guard let change = deferredChange ?? client.nextChange() else { return }
            let separator = pending.isEmpty ? 0 : 1
            let fits = pending.count + separator + change.count <= Self.maxUndeliveredBytes
            // A single change is allowed to exceed the cap; combining it with
            // another change is never allowed to do so.
            guard fits || (pending.isEmpty && separator == 0) else {
                deferredChange = change
                return
            }
            deferredChange = nil
            if separator != 0 { pending.append(0x0a) }
            pending.append(change)
        }
    }

    private func drain() {
        guard !pendingDelivery, !pending.isEmpty, let onChange else { return }
        pendingDelivery = true
        let batch = pending
        deliveredPrefixCount = batch.count
        onChange(batch)
    }

    private func fail() {
        guard !closed else { return }
        closed = true
        client.setSendHandler(nil)
        _ = client.disconnected()
        connection?.cancel()
        connection = nil
        input.removeAll()
        pending.removeAll()
        deferredChange = nil
        deliveredPrefixCount = 0
        let callback = onClose
        onChange = nil
        onClose = nil
        pendingDelivery = false
        callback?()
    }
}

public import Foundation
import CmuxNextAgentActivity

/// Drives an `AcpmuxClient` over the existing serial socket connection. It
/// pauses consumption at one undelivered 1 MiB batch and resumes only after
/// the consumer acknowledges that batch; bytes are never dropped.
/// All mutable state is confined to the private utility queue.
public nonisolated final class AcpmuxClientByteConnection: @unchecked Sendable { // crash-allow: callbacks hop back to this serial queue before touching state
    public static let maxUndeliveredBytes = 1 << 20
    /// The most one batch holds (``maxUndeliveredBytes`` unless the caller passes less; a pane's
    /// chat host passes 64 KiB). A single change over it is a batch alone. One socket read is at
    /// most this much too, so unread bytes stay within it.
    public let maxBatchBytes: Int
    /// Each change goes into a batch as a 4-byte big-endian length, then its bytes, instead of
    /// joined by newlines: a chat blob change holds a newline. A framed batch takes no change
    /// while it is out, so its acknowledgement covers exactly what was handed over.
    private let framesChanges: Bool
    /// The drop callback a ``reconnect(path:refused:)`` opens again with.
    private var reopenClose: (@Sendable () -> Void)?
    private var reads = 0
    private var bytesRead = 0
    private let client: AcpmuxClient
    private let queue = DispatchQueue(label: "cmux.acpmux-client.driver", qos: .utility) // qos-allow: socket bytes are background transport work
    private var input = Data()
    private var pending = Data()
    private var deferredChange: Data?
    private var pendingDelivery = false
    private var connection: AgentActivityLineConnection?
    private var onChange: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false

    public init(client: AcpmuxClient, maxBatchBytes: Int = maxUndeliveredBytes, framesChanges: Bool = false) {
        self.client = client
        self.maxBatchBytes = max(1, maxBatchBytes)
        self.framesChanges = framesChanges
    }

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
            open(path: path, onClose: onClose)
        }
    }

    /// Opens the socket again after it dropped (its `onClose` ran), on the same client: the core
    /// resumes its subs, and the batch not yet acknowledged and the change it could not hold stay,
    /// so nothing taken out of the core is lost. `refused` runs instead when the driver was
    /// stopped or failed; the caller then makes a new one.
    public func reconnect(path: String, refused: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard closed, onChange != nil, let onClose = reopenClose else { return refused() }
            reopenClose = nil
            closed = false
            input.removeAll()
            self.onClose = onClose
            open(path: path, onClose: onClose)
        }
    }

    private func open(path: String, onClose: @escaping @Sendable () -> Void) {
        let connection = AgentActivityLineConnection(path: path, readLimit: maxBatchBytes)
        self.connection = connection
        guard client.connected() == 0 else {
            fail()
            return
        }
        var upgrade = Data()
        while let bytes = client.takeSend() { upgrade.append(bytes) }
        connection.startBytes(send: upgrade, onBytes: { [weak self] bytes in
            guard let self else { return }
            self.queue.async { self.receive(bytes) }
        }, onClose: { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.closed = true
                self.client.setSendHandler(nil)
                _ = self.client.disconnected()
                self.onClose = nil
                self.reopenClose = onClose
                onClose()
            }
        })
        client.setSendHandler { [weak connection] bytes in connection?.send(bytes) }
    }

    public func acknowledgeBatch() {
        queue.async { [self] in
            pending.removeAll(keepingCapacity: true)
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
            let prefix = input
            input.removeAll()
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
        reads += 1
        bytesRead += bytes.count
        input.append(bytes)
        processInput()
    }

    private func processInput() {
        guard !closed else { return }
        drainChanges()
        while !input.isEmpty, pending.count < maxBatchBytes {
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
        while pending.count < maxBatchBytes, !(framesChanges && pendingDelivery) {
            guard let change = deferredChange ?? client.nextChange() else { return }
            let separator = framesChanges ? 4 : (pending.isEmpty ? 0 : 1)
            let fits = pending.count + separator + change.count <= maxBatchBytes
            // A single change is allowed to exceed the cap; combining it with
            // another change is never allowed to do so.
            guard fits || pending.isEmpty else {
                deferredChange = change
                return
            }
            deferredChange = nil
            if framesChanges {
                withUnsafeBytes(of: UInt32(truncatingIfNeeded: change.count).bigEndian) { pending.append(contentsOf: $0) }
            } else if separator != 0 {
                pending.append(0x0a)
            }
            pending.append(change)
        }
    }

    private func drain() {
        guard !pendingDelivery, !pending.isEmpty, let onChange else { return }
        pendingDelivery = true
        let batch = pending
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
        let callback = onClose
        onChange = nil
        onClose = nil
        pendingDelivery = false
        callback?()
    }

    /// What the driver holds now (tests): the batch, the change it could not hold, the bytes the
    /// core has not taken, the number of socket reads so far and the bytes they held.
    internal func heldForTesting() async -> (pending: Int, deferred: Int, input: Int, reads: Int, bytes: Int) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: (pending.count, deferredChange?.count ?? 0, input.count, reads, bytesRead))
            }
        }
    }

    /// Fails the connection as bad bytes would (tests): it closes and `onClose` runs.
    internal func failForTesting() {
        queue.async { [self] in fail() }
    }
}

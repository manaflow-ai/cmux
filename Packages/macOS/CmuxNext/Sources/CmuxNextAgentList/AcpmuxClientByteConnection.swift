import Foundation
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
    private var pendingDelivery = false
    private var connection: AgentActivityLineConnection?
    private var onChange: (@Sendable (Data) -> Void)?
    private var closed = false

    public init(client: AcpmuxClient) { self.client = client }

    public func start(path: String, upgrade: Data, onChange: @escaping @Sendable (Data) -> Void,
                      onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            self.onChange = onChange
            let connection = AgentActivityLineConnection(path: path)
            self.connection = connection
            connection.startBytes(send: upgrade, onBytes: { [weak self] bytes in
                self?.queue.async { self?.receive(bytes) }
            }, onClose: { [weak self] in
                self?.queue.async {
                    guard let self, !self.closed else { return }
                    self.closed = true
                    onClose()
                }
            })
        }
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
            connection?.cancel()
            connection = nil
            input.removeAll()
            pending.removeAll()
            onChange = nil
        }
    }

    private func receive(_ bytes: Data) {
        guard !closed else { return }
        input.append(bytes)
        processInput()
    }

    private func processInput() {
        guard !closed else { return }
        while !input.isEmpty, pending.count < Self.maxUndeliveredBytes {
            let consumed = client.received(input)
            if consumed > 0 {
                input.removeSubrange(input.startIndex..<input.index(input.startIndex, offsetBy: min(consumed, input.count)))
            }
            drainChanges()
            if consumed == 0 { break }
        }
        // The raw connection is suspended for this chunk; keep it suspended while
        // either unread input or one undelivered <=1 MiB batch remains.
        if pending.isEmpty, input.isEmpty {
            connection?.resumeBytes()
        } else {
            drain()
        }
    }

    private func drainChanges() {
        while pending.count < Self.maxUndeliveredBytes, let change = client.nextChange() {
            if !pending.isEmpty { pending.append(0x0a) }
            pending.append(change)
        }
    }

    private func drain() {
        guard !pendingDelivery, !pending.isEmpty, let onChange else { return }
        pendingDelivery = true
        let batch = pending
        onChange(batch)
    }
}

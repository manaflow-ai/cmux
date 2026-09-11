import Foundation

/// Serializes all application frames, including delivery receipts, through one bounded sender.
actor V2OrderedSocket: V2ControlSocket {
    private let transport: any V2ControlSocket
    private var queue: [Write] = []
    private var active: Write?
    private var bytes = 0
    private var closed = false
    private var sender: Task<Void, Never>?

    private struct Write {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
    }

    init(transport: any V2ControlSocket) { self.transport = transport }

    func send(_ data: Data) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw V2ControlFailure.unavailable }
            guard queue.count + (active == nil ? 0 : 1) < 1024, bytes + data.count <= 2 * 1024 * 1024 else {
                throw V2ControlFailure.capacityExceeded
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.append(Write(id: id, data: data, continuation: continuation))
                bytes += data.count
                if sender == nil { sender = Task { await self.drain() } }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func receive() async throws -> Data { try await transport.receive() }
    func ping() async throws { try await transport.ping() }

    func close() async {
        guard !closed else { return }
        closed = true
        sender?.cancel()
        if let active { active.continuation.resume(throwing: V2ControlFailure.stopped) }
        active = nil
        for item in queue { item.continuation.resume(throwing: V2ControlFailure.stopped) }
        queue.removeAll()
        bytes = 0
        await transport.close()
    }

    private func cancel(_ id: UUID) {
        if let active, active.id == id {
            self.active = nil
            bytes -= active.data.count
            active.continuation.resume(throwing: V2ControlFailure.stopped)
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let item = queue.remove(at: index)
            bytes -= item.data.count
            item.continuation.resume(throwing: V2ControlFailure.stopped)
        }
    }

    private func drain() async {
        defer { sender = nil }
        while !closed, !queue.isEmpty, !Task.isCancelled {
            let item = queue.removeFirst()
            active = item
            let result: Result<Void, any Error>
            do { try await transport.send(item.data); result = .success(()) }
            catch { result = .failure(error) }
            if active?.id == item.id {
                active = nil
                bytes -= item.data.count
                item.continuation.resume(with: result)
            }
        }
    }
}

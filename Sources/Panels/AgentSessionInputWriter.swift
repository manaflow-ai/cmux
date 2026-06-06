import Foundation

final class AgentSessionInputWriter {
    private static let maxQueuedBytes = 1024 * 1024

    private struct PendingWrite {
        let data: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var queuedWrites: [PendingWrite] = []
    private var queuedByteCount = 0
    private var isClosed = false
    private var isDraining = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        try await withCheckedThrowingContinuation { continuation in
            enqueue(data, continuation: continuation)
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        let writes = queuedWrites
        queuedWrites.removeAll()
        queuedByteCount = 0
        lock.unlock()

        for write in writes {
            write.continuation.resume(throwing: AgentSessionBridgeError.providerNotReady("Agent"))
        }
    }

    private func enqueue(_ data: Data, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            continuation.resume(throwing: AgentSessionBridgeError.providerNotReady("Agent"))
            return
        }
        guard queuedByteCount + data.count <= Self.maxQueuedBytes else {
            lock.unlock()
            continuation.resume(throwing: AgentSessionBridgeError.providerNotReady("Agent"))
            return
        }

        queuedWrites.append(PendingWrite(data: data, continuation: continuation))
        queuedByteCount += data.count
        let shouldStartDrain = !isDraining
        if shouldStartDrain {
            isDraining = true
        }
        lock.unlock()

        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        while true {
            let write: PendingWrite
            lock.lock()
            if queuedWrites.isEmpty {
                isDraining = false
                lock.unlock()
                return
            }
            write = queuedWrites.removeFirst()
            queuedByteCount -= write.data.count
            lock.unlock()

            do {
                try fileHandle.write(contentsOf: write.data)
                write.continuation.resume()
            } catch {
                write.continuation.resume(throwing: error)
                close()
                return
            }
        }
    }
}

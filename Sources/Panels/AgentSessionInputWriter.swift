import Foundation

actor AgentSessionInputWriter {
    private static let maxQueuedBytes = 1024 * 1024

    private let fileHandle: FileHandle
    private var queuedWrites: [(data: Data, continuation: CheckedContinuation<Void, Error>)] = []
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
        close(queuedWriteError: AgentSessionBridgeError.providerNotReady("Agent"))
    }

    private func close(queuedWriteError: Error) {
        isClosed = true
        let writes = queuedWrites
        queuedWrites.removeAll()
        queuedByteCount = 0

        for write in writes {
            write.continuation.resume(throwing: queuedWriteError)
        }
    }

    private func enqueue(_ data: Data, continuation: CheckedContinuation<Void, Error>) {
        guard !isClosed else {
            continuation.resume(throwing: AgentSessionBridgeError.providerNotReady("Agent"))
            return
        }
        guard queuedByteCount + data.count <= Self.maxQueuedBytes else {
            continuation.resume(throwing: AgentSessionBridgeError.providerNotReady("Agent"))
            return
        }

        queuedWrites.append((data: data, continuation: continuation))
        queuedByteCount += data.count
        let shouldStartDrain = !isDraining
        if shouldStartDrain {
            isDraining = true
        }

        if shouldStartDrain {
            Task(priority: .utility) {
                self.drain()
            }
        }
    }

    private func drain() {
        while true {
            if queuedWrites.isEmpty {
                isDraining = false
                return
            }
            let write = queuedWrites.removeFirst()
            queuedByteCount -= write.data.count

            do {
                try fileHandle.write(contentsOf: write.data)
                write.continuation.resume()
            } catch {
                write.continuation.resume(throwing: error)
                close(queuedWriteError: error)
                return
            }
        }
    }
}

import Foundation

final class AgentSessionInputWriter {
    private static let maxQueuedBytes = 1024 * 1024

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var queuedData: [Data] = []
    private var queuedByteCount = 0
    private var isClosed = false
    private var isDraining = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw AgentSessionBridgeError.providerNotReady("Agent")
        }
        guard queuedByteCount + data.count <= Self.maxQueuedBytes else {
            lock.unlock()
            throw AgentSessionBridgeError.providerNotReady("Agent")
        }

        queuedData.append(data)
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

    func close() {
        lock.lock()
        isClosed = true
        queuedData.removeAll()
        queuedByteCount = 0
        lock.unlock()
    }

    private func drain() {
        while true {
            let data: Data
            lock.lock()
            if queuedData.isEmpty {
                isDraining = false
                lock.unlock()
                return
            }
            data = queuedData.removeFirst()
            queuedByteCount -= data.count
            lock.unlock()

            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                close()
                return
            }
        }
    }
}

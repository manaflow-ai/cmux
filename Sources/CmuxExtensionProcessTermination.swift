import Foundation

final class CmuxExtensionProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>?
        lock.lock()
        if let pendingContinuation = self.continuation {
            self.continuation = nil
            continuation = pendingContinuation
        } else {
            self.status = status
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32?
            lock.lock()
            if let status {
                completedStatus = status
            } else {
                self.continuation = continuation
                completedStatus = nil
            }
            lock.unlock()

            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }
}

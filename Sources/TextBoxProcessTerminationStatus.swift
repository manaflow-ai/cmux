import Foundation

actor TextBoxProcessTerminationStatus {
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        if let status {
            return status
        }

        return await withCheckedContinuation { continuation in
            if let status {
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        continuation?.resume(returning: status)
        continuation = nil
    }
}

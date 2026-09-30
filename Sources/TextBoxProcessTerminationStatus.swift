import Foundation

actor TextBoxProcessTerminationStatus {
    private var status: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        if let status {
            return status
        }

        return await withCheckedContinuation { continuation in
            if let status {
                continuation.resume(returning: status)
            } else {
                self.continuations.append(continuation)
            }
        }
    }

    func finish(status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume(returning: status)
        }
    }
}

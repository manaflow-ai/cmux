import Foundation

final class MobileDebugLogOperationQueue: Sendable {
    static let defaultPendingOperationLimit = 512

    private let mailbox: MobileDebugLogOperationMailbox

    init(
        sink: MobileDebugLogSink,
        pendingOperationLimit: Int = MobileDebugLogOperationQueue.defaultPendingOperationLimit
    ) {
        self.mailbox = MobileDebugLogOperationMailbox(
            sink: sink,
            pendingAppendLimit: pendingOperationLimit
        )
    }

    func append(_ message: String) {
        let mailbox = mailbox
        let issuedAt = ContinuousClock.now
        Task.detached {
            await mailbox.append(message, issuedAt: issuedAt)
        }
    }

    func clear() -> Task<Void, Never> {
        let mailbox = mailbox
        let issuedAt = ContinuousClock.now
        return Task.detached {
            await mailbox.clear(issuedAt: issuedAt)
        }
    }
}

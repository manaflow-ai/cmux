@testable import CmuxNotifications

/// Controls status-read completion independently of admission without polling.
@MainActor
final class NotificationAuthorizationRefreshReadProbe {
    typealias ResultType = Result<UserNotificationAuthorizationStatus, UserNotificationCenterFailure>
    private var replies: [CheckedContinuation<ResultType, Never>] = []
    private var readWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func read() async -> ResultType {
        await withCheckedContinuation { continuation in
            replies.append(continuation)
            if let readWaiter, replies.count >= readWaiter.count {
                self.readWaiter = nil
                readWaiter.continuation.resume()
            }
        }
    }

    func waitForRead(_ count: Int) async {
        guard replies.count < count else { return }
        await withCheckedContinuation { readWaiter = (count, $0) }
    }

    func completeRead(_ index: Int, with result: ResultType) {
        replies[index].resume(returning: result)
    }
}

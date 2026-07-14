import Foundation

struct RecordingPullRequestRefreshWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

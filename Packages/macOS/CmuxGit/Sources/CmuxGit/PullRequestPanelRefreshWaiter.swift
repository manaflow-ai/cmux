import Foundation

struct PullRequestPanelRefreshWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

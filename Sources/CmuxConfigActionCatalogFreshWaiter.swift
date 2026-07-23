import Foundation

struct CmuxConfigActionCatalogFreshWaiter {
    let minimumRefreshSequence: UInt64
    let directory: String?
    let continuation: CheckedContinuation<CmuxConfigActionCatalogSnapshot?, Never>
    let deadlineTimer: Timer?
}

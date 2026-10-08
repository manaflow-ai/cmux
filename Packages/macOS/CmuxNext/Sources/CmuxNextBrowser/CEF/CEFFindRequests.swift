import Foundation

/// The find-in-page request of one Chromium tab. Chromium answers each
/// `cmux_shim_find` with FIND_RESULT events; only the final one answers the
/// caller. A new search, Clear Find or the page ending answers a pending
/// request with `.none`, so a caller never waits forever.
struct CEFFindRequests {
    private var continuation: CheckedContinuation<BrowserFindResult, Never>?
    private var nextID: Int32 = 1

    /// Starts a request (answering any pending one with `.none`) and returns
    /// the find id to pass to Chromium.
    mutating func begin(_ continuation: CheckedContinuation<BrowserFindResult, Never>) -> Int32 {
        cancel()
        self.continuation = continuation
        defer { nextID += 1 }
        return nextID
    }

    /// A FIND_RESULT event: the final one answers the pending request.
    mutating func result(count: Int, active: Int, isFinal: Bool) {
        guard isFinal, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: BrowserFindResult(
            matchFound: count > 0, matchCount: count, currentIndex: count > 0 ? active : nil
        ))
    }

    /// Answers a pending request with `.none`.
    mutating func cancel() {
        continuation?.resume(returning: .none)
        continuation = nil
    }
}

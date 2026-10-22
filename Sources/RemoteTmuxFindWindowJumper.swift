import Foundation

/// Opens the find bar for find-window jumps, one at a time.
///
/// A match older than the attach seed needs the pane's full history loaded first,
/// which can take a while on a long history. A newer jump replaces the waiting one,
/// and a load that ends after focus moved to another pane opens nothing.
@MainActor
final class RemoteTmuxFindWindowJumper {
    private var pending: Task<Void, Never>?

    /// Opens the find bar now, or after loading the full history.
    ///
    /// - Parameters:
    ///   - loadsFullHistoryFirst: load the pane's full history before opening search.
    ///   - reseed: loads the full history.
    ///   - isStillTarget: whether the jumped-to pane still has focus.
    ///   - openSearch: opens the pane's find bar on the match.
    /// - Returns: the load, for tests to await; nil when search opened at once.
    @discardableResult
    func jump(
        loadsFullHistoryFirst: Bool,
        reseed: @escaping @MainActor () async -> RemoteTmuxFullHistorySeedOutcome,
        isStillTarget: @escaping @MainActor () -> Bool,
        openSearch: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        pending?.cancel()
        pending = nil
        guard loadsFullHistoryFirst else {
            openSearch()
            return nil
        }
        // A failed load still opens the find bar: the match may be in the rows the
        // surface holds, and the bar's full-history button shows the failure and retries.
        let task = Task { @MainActor in
            _ = await reseed()
            guard !Task.isCancelled, isStillTarget() else { return }
            openSearch()
        }
        pending = task
        return task
    }
}

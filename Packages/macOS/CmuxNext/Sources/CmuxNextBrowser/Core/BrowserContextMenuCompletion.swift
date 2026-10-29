import CmuxNextCompat

/// The one answer of a ``BrowserContextMenuRequest``, as a token that answers nil
/// (dismissed) when it is released unanswered.
///
/// The request holds it, so a host that drops the request dismisses the menu without the
/// request needing a main-actor `deinit` (cx-t7hu: an isolated deinit hop traps inside an
/// action's task-local scope). The release may happen on any thread: the nil answer is queued
/// on the main run loop (``MainRunLoopBlock``), so it always reaches the engine, on the main
/// thread, after the code that dropped the request has returned.
nonisolated final class BrowserContextMenuCompletion {
    private var completion: (@MainActor (Int?) -> Void)?

    init(_ completion: @escaping @MainActor (Int?) -> Void) {
        self.completion = completion
    }

    /// Answers `id` (nil: dismissed); later answers and the release do nothing.
    @MainActor
    func complete(_ id: Int?) {
        let completion = completion
        self.completion = nil
        completion?(id)
    }

    deinit {
        guard let completion else { return }
        MainRunLoopBlock.perform { completion(nil) }
    }
}

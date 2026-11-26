import Foundation

/// Defers and coalesces Vault table mutations past the originating layout callback.
@MainActor
final class SessionIndexTableMutationScheduler {
    private var pendingApply: SessionIndexTableApplyInput?
    private var isFlushScheduled = false
    private let applyFlush: @MainActor (SessionIndexTableApplyInput) -> Void

    init(applyFlush: @escaping @MainActor (SessionIndexTableApplyInput) -> Void) {
        self.applyFlush = applyFlush
    }

    func stageApply(_ input: SessionIndexTableApplyInput) {
        pendingApply = input
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // RunLoop guarantees main-thread delivery, but Foundation does
            // not annotate this callback with MainActor.
            MainActor.assumeIsolated {
                self?.flushPendingApply()
            }
        }
    }

    /// Drops a queued projection before an interactive table mutation applies
    /// its authoritative snapshot synchronously.
    func cancelPending() {
        pendingApply = nil
        // Keep the already scheduled RunLoop turn reserved. Resetting this
        // flag here allows a second callback to race the first one and makes
        // a parent projection land in a separate layout transaction.
    }

    private func flushPendingApply() {
        let input = pendingApply
        pendingApply = nil
        isFlushScheduled = false
        if let input {
            applyFlush(input)
        }
    }
}

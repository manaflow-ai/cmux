import Foundation

/// A bounded page-metadata change delivered from WebKit to observable state.
struct BrowserPageMetadataUpdate: Equatable {
    let url: URL?
    let title: String?
    let includesURL: Bool
    let includesTitle: Bool
}

/// Coalesces synchronous WebKit title and History API churn at the actor-event
/// boundary while preserving an explicit final flush for navigation teardown.
@MainActor
final class BrowserPageMetadataEventCoalescer {
    private let commit: @MainActor (BrowserPageMetadataUpdate) -> Void
    private var pendingURL: URL?
    private var pendingTitle: String?
    private var includesURL = false
    private var includesTitle = false
    private var scheduledCommit: Task<Void, Never>?

    init(commit: @escaping @MainActor (BrowserPageMetadataUpdate) -> Void) {
        self.commit = commit
    }

    func receiveURL(_ url: URL) {
        pendingURL = url
        includesURL = true
        scheduleCommit()
    }

    func receiveTitle(_ title: String?) {
        pendingTitle = title
        includesTitle = true
        scheduleCommit()
    }

    func flush() {
        scheduledCommit?.cancel()
        scheduledCommit = nil
        commitPending()
    }

    func discardPending() {
        scheduledCommit?.cancel()
        scheduledCommit = nil
        clearPending()
    }

    func waitForScheduledCommit() async {
        await scheduledCommit?.value
    }

    private func scheduleCommit() {
        scheduledCommit?.cancel()
        scheduledCommit = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    private func commitPending() {
        guard includesURL || includesTitle else { return }
        let update = BrowserPageMetadataUpdate(
            url: pendingURL,
            title: pendingTitle,
            includesURL: includesURL,
            includesTitle: includesTitle
        )
        clearPending()
        scheduledCommit = nil
        commit(update)
    }

    private func clearPending() {
        pendingURL = nil
        pendingTitle = nil
        includesURL = false
        includesTitle = false
    }

    isolated deinit {
        scheduledCommit?.cancel()
    }
}

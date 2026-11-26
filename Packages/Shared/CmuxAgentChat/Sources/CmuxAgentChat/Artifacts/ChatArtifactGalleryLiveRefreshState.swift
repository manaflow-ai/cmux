/// Defers gallery generation changes while the user is reading away from the top.
public struct ChatArtifactGalleryLiveRefreshState: Sendable, Equatable {
    private var pendingSnapshot: ChatArtifactGallerySnapshot?

    /// Number of unseen paths waiting for explicit application.
    public private(set) var pendingNewFileCount = 0

    /// Creates an empty live-refresh state.
    public init() {}

    /// Receives a fresh first page and decides whether it is safe to show now.
    ///
    /// - Parameters:
    ///   - fresh: First page from the latest session generation.
    ///   - displayed: Snapshot currently rendered by the gallery.
    ///   - isAtTopOrFits: Whether inserting leading rows cannot disturb a reading position.
    /// - Returns: A reconciled snapshot to display immediately, or `nil` when a pill should be shown.
    public mutating func receive(
        fresh: ChatArtifactGallerySnapshot,
        displayed: ChatArtifactGallerySnapshot,
        isAtTopOrFits: Bool
    ) -> ChatArtifactGallerySnapshot? {
        guard fresh.generation != displayed.generation else { return nil }
        let displayedPaths = Set((displayed.created + displayed.attached + displayed.referenced).map(\.path))
        let freshPaths = Set((fresh.created + fresh.attached + fresh.referenced).map(\.path))
        let newFileCount = freshPaths.subtracting(displayedPaths).count
        let reconciled = displayed.reconciling(withFreshFirstPage: fresh)

        guard !isAtTopOrFits, newFileCount > 0 else {
            pendingSnapshot = nil
            pendingNewFileCount = 0
            return reconciled
        }
        pendingSnapshot = fresh
        pendingNewFileCount = newFileCount
        return nil
    }

    /// Applies the newest deferred first page and clears the pending pill.
    ///
    /// - Parameter displayed: Snapshot currently rendered by the gallery.
    /// - Returns: The reconciled snapshot, or `nil` when no refresh is pending.
    public mutating func applyPending(
        to displayed: ChatArtifactGallerySnapshot
    ) -> ChatArtifactGallerySnapshot? {
        guard let pendingSnapshot else { return nil }
        self.pendingSnapshot = nil
        pendingNewFileCount = 0
        return displayed.reconciling(withFreshFirstPage: pendingSnapshot)
    }

    /// Drops a deferred refresh when the session or scope changes.
    public mutating func reset() {
        pendingSnapshot = nil
        pendingNewFileCount = 0
    }
}

/// The completed outcome of eagerly loading referenced gallery pages.
public struct ChatArtifactGalleryEagerPagingResult: Sendable, Equatable {
    /// Accumulated rows and the cursor that remains after loading.
    public let snapshot: ChatArtifactGallerySnapshot
    /// Whether loading stopped because more than the configured row cap exists.
    public let reachedSafetyCap: Bool
    /// Whether the host rejected an obsolete generation cursor.
    public let requiresPagingRestart: Bool

    /// Creates an eager-paging result.
    ///
    /// - Parameters:
    ///   - snapshot: Accumulated rows and remaining cursor.
    ///   - reachedSafetyCap: Whether the row cap prevented complete loading.
    ///   - requiresPagingRestart: Whether paging must restart from a first page.
    public init(
        snapshot: ChatArtifactGallerySnapshot,
        reachedSafetyCap: Bool,
        requiresPagingRestart: Bool = false
    ) {
        self.snapshot = snapshot
        self.reachedSafetyCap = reachedSafetyCap
        self.requiresPagingRestart = requiresPagingRestart
    }
}

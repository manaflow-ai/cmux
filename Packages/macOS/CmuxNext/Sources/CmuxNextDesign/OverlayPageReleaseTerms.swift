public import CmuxNextCompat
public import CmuxNextWakeups

/// The app's terms for ``OverlayPageRelease`` (feature `memoryOverlayPagesOnFirstUse`): how long hidden overlay
/// content is kept, the one deadline placer and the memory coordinator. The composition root makes one and hands it
/// to each owner of overlay content (the icon picker, the update card's highlights, every Extensions bubble), which
/// makes its own release with ``release(owner:_:)``; with the feature off it hands none and nothing changes.
@MainActor
public struct OverlayPageReleaseTerms {
    /// How long hidden content is kept at normal pressure.
    public let releaseAfter: Duration
    /// The app's one deadline placer (`AppServices.mainDeadlines`).
    public let deadlines: MainDeadlineScheduler
    /// The app's memory coordinator; nil releases on the deadline only.
    public let memory: (any MemoryConsumerRegistry)?

    /// - Parameters:
    ///   - releaseAfter: How long hidden content is kept at normal pressure (the feature's `releaseAfter`).
    ///   - deadlines: The app's one deadline placer.
    ///   - memory: The app's memory coordinator.
    public init(releaseAfter: Duration = OverlayPageRelease.defaultReleaseAfter, deadlines: MainDeadlineScheduler,
                memory: (any MemoryConsumerRegistry)?) {
        self.releaseAfter = releaseAfter
        self.deadlines = deadlines
        self.memory = memory
    }

    /// A release for `owner`'s content on a background deadline of its own; `release` drops it, false while in use.
    public func release(owner: String, _ release: @escaping @MainActor () -> Bool) -> OverlayPageRelease {
        OverlayPageRelease(owner: owner, releaseAfter: releaseAfter,
                           deadline: MainDeadline(owner: "\(owner).release", workClass: .background, scheduler: deadlines),
                           memory: memory, release: release)
    }
}

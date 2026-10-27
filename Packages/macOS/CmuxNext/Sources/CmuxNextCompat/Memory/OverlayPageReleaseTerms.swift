/// The app's terms for ``OverlayPageRelease``: how long hidden overlay content is kept and the one planner that
/// releases it. The composition root makes them (features `memoryOverlayPagesOnFirstUse`, and
/// `memoryOpenPanelOnFirstUse` for the file picker) and hands them to each owner of overlay content (the icon picker,
/// the update card's highlights, every Extensions bubble, the made-ahead file picker), which makes its own release
/// with ``release(owner:inUse:drop:)``; with the features off it hands none and nothing changes.
@MainActor
public struct OverlayPageReleaseTerms {
    /// How long hidden content is kept at the Memory Saver mode's medium and normal pressure.
    public let releaseAfter: Duration
    /// The App's one overlay page planner.
    public let planner: any OverlayPagePlanner

    /// - Parameters:
    ///   - releaseAfter: How long hidden content is kept (the feature's `releaseAfter`).
    ///   - planner: The App's one overlay page planner.
    public init(releaseAfter: Duration = OverlayPageRelease.defaultReleaseAfter, planner: any OverlayPagePlanner) {
        self.releaseAfter = releaseAfter
        self.planner = planner
    }

    /// A release for `owner`'s content: `inUse` says hidden content must stay for now, `drop` lets it go.
    public func release(owner: String, inUse: @escaping @MainActor () -> Bool = { false },
                        drop: @escaping @MainActor () -> Void) -> OverlayPageRelease {
        OverlayPageRelease(owner: owner, releaseAfter: releaseAfter, planner: planner, inUse: inUse, drop: drop)
    }
}

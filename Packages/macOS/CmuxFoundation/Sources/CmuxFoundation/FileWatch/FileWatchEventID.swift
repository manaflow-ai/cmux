/// Stable FSEvents identifier for one filesystem event.
///
/// Event IDs let independent watchers of the same paths recognize duplicate
/// delivery without inferring identity from timing. Within a throttle window,
/// ``RecursivePathWatcher`` emits the greatest ID because a scan after that
/// event observes the filesystem state produced by every earlier event.
public nonisolated struct FileWatchEventID: Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whether an FSEvents batch has a stable deduplication watermark.
public nonisolated enum FileWatchEventIdentity: Equatable, Sendable {
    /// Normal delivery. Equal or older IDs from another watcher are duplicate
    /// observations of filesystem state already covered by this watermark.
    case stable(FileWatchEventID)
    /// FSEvents reported a dropped batch or requested a subtree rescan. Every
    /// delivery must advance authority because its exact event identity is not
    /// trustworthy.
    case mustRescan
    /// FSEvents IDs wrapped. The consumer must advance authority and discard its
    /// prior stable watermark so the next lower ID can establish a new sequence.
    case eventIDsWrapped

    func merged(with other: Self) -> Self {
        switch (self, other) {
        case (.eventIDsWrapped, _), (_, .eventIDsWrapped):
            return .eventIDsWrapped
        case (.mustRescan, _), (_, .mustRescan):
            return .mustRescan
        case (.stable(let first), .stable(let second)):
            return .stable(max(first, second))
        }
    }
}

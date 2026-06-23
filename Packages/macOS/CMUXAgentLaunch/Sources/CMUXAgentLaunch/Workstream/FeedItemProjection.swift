import Foundation

/// The two ways the Feed can be filtered when projecting workstream items into
/// row snapshots.
///
/// This is the pure discriminant the projection branches on. The app-side
/// `Filter` type that drives the control bar owns the localized labels and SF
/// Symbol names; it maps to this value before asking ``FeedItemProjection`` for
/// snapshots, so no localized UI text lives in the package.
public enum FeedFilterMode: String, Sendable, CaseIterable, Equatable {
    /// Only items that require a user response (permission requests, exit
    /// plans, questions).
    case actionable
    /// Actionable kinds plus todos and stop events; telemetry stays hidden.
    case activity
}

/// Pure projection of `[WorkstreamItem]` into the `[FeedItemSnapshot]` the Feed
/// list renders.
///
/// Constructed with the active ``FeedFilterMode`` and then queried; every method
/// is a deterministic transform over the supplied items that touches only
/// workstream value types, so it holds no UI state and observes no store. The
/// list view owns the SwiftUI body and asks an instance of this value for the
/// snapshots and groupings it needs to render.
public struct FeedItemProjection: Sendable, Equatable {
    /// The filter the projection applies when selecting and ordering items.
    public let filter: FeedFilterMode

    /// Creates a projection for the given filter mode.
    ///
    /// - Parameter filter: The filter applied to every projection call.
    public init(filter: FeedFilterMode) {
        self.filter = filter
    }

    /// Projects the source items into ordered, filter-scoped row snapshots.
    ///
    /// Each snapshot is tagged with the most recent user-prompt text in its
    /// workstream so a card can show a "You: …" echo for context.
    ///
    /// - Parameter items: The full, unfiltered workstream item list.
    /// - Returns: The snapshots the list should render, newest first.
    public func visibleSnapshots(_ items: [WorkstreamItem]) -> [FeedItemSnapshot] {
        let lastPromptByWorkstream = lastPromptByWorkstream(items)
        return filtered(items).map { item in
            FeedItemSnapshot(
                item: item,
                userPromptEcho: lastPromptByWorkstream[item.workstreamId]
            )
        }
    }

    /// Selects and orders the items that belong in the current filter.
    ///
    /// Actionable mode keeps only actionable kinds; activity mode also keeps
    /// todos and stop events. Tool use, user prompts, assistant messages,
    /// session markers, and raw notifications are intentionally excluded from
    /// activity: they're too noisy for a sidebar and already visible in the
    /// agent's terminal or the cmux notification system. Stop events render a
    /// "reply to Claude" textbox so the user can nudge Claude without switching
    /// focus to the terminal.
    ///
    /// Items are returned newest first. Status is not a sort key: resolved
    /// items stay in the chronological slot where they arrived so the user's
    /// mental map of "this was the second request I got" doesn't get shuffled
    /// when they answer it.
    ///
    /// - Parameter items: The full, unfiltered workstream item list.
    /// - Returns: The filtered items, newest first.
    public func filtered(_ items: [WorkstreamItem]) -> [WorkstreamItem] {
        let base: [WorkstreamItem]
        switch filter {
        case .actionable:
            base = items.filter { $0.kind.isActionable }
        case .activity:
            base = items.filter { item in
                item.kind.isActionable
                    || item.kind == .todos
                    || item.kind == .stop
            }
        }
        return Array(base.reversed())
    }

    /// Splits already-projected snapshots into the stable/history grouping the
    /// activity surface renders, preserving order within each group.
    ///
    /// - Parameter snapshots: The snapshots to partition.
    /// - Returns: The stable group, the history group, and their concatenation
    ///   in display order.
    public func activitySnapshotGroups(_ snapshots: [FeedItemSnapshot]) -> ActivitySnapshotGroups {
        var stable: [FeedItemSnapshot] = []
        var history: [FeedItemSnapshot] = []
        stable.reserveCapacity(snapshots.count)
        history.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if prefersStableSurface(snapshot) {
                stable.append(snapshot)
            } else {
                history.append(snapshot)
            }
        }
        return ActivitySnapshotGroups(stable: stable, history: history, ordered: stable + history)
    }

    /// Whether a snapshot belongs in the stable (pinned) activity group rather
    /// than the scroll-back history group.
    ///
    /// Pending items and stop events stay pinned so the user can act on them;
    /// everything else falls into history.
    ///
    /// - Parameter snapshot: The snapshot to classify.
    /// - Returns: `true` when the snapshot should pin to the stable surface.
    public func prefersStableSurface(_ snapshot: FeedItemSnapshot) -> Bool {
        snapshot.status.isPending || snapshot.kind == .stop
    }

    /// Walks the full items list (not just the filtered visible set), ordered
    /// by `createdAt`, and records the most recent user-prompt text per
    /// `workstreamId`. Rows consult this dict to show a "You: …" echo line at
    /// the top of their card.
    ///
    /// - Parameter items: The full, unfiltered workstream item list.
    /// - Returns: The latest user-prompt text keyed by `workstreamId`.
    public func lastPromptByWorkstream(_ items: [WorkstreamItem]) -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            if case .userPrompt(let text) = item.payload, !text.isEmpty {
                out[item.workstreamId] = text
            }
        }
        return out
    }

    /// Stable (pinned) and history partitions of the activity surface, plus
    /// their concatenation in display order.
    public struct ActivitySnapshotGroups: Sendable, Equatable {
        /// Pinned items that stay at the top of the activity surface.
        public let stable: [FeedItemSnapshot]
        /// Scroll-back history items below the stable group.
        public let history: [FeedItemSnapshot]
        /// `stable` followed by `history`, in display order.
        public let ordered: [FeedItemSnapshot]

        /// Creates a grouping from its two partitions and their display order.
        ///
        /// - Parameters:
        ///   - stable: The pinned items.
        ///   - history: The scroll-back items.
        ///   - ordered: The two groups concatenated in display order.
        public init(
            stable: [FeedItemSnapshot],
            history: [FeedItemSnapshot],
            ordered: [FeedItemSnapshot]
        ) {
            self.stable = stable
            self.history = history
            self.ordered = ordered
        }
    }
}

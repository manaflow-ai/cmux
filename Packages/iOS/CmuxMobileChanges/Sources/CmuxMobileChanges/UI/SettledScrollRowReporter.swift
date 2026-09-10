import SwiftUI

/// Last row seen near the top of the diff scroll view, kept OUTSIDE SwiftUI
/// state on purpose: it changes on every frame of a scroll, and routing it
/// through `@State` or a `scrollPosition` binding makes SwiftUI a second
/// owner of the scroll offset. That ownership fight is what killed fling
/// deceleration, rubber-banding, and pull-to-refresh displacement on real
/// diffs (the offset was re-resolved against the tracked row on every lazy
/// row materialization). UIKit physics own the offset; we only observe.
@MainActor
final class ScrollRowTracker {
    var topRowID: String?

    nonisolated init(topRowID: String?) {
        self.topRowID = topRowID
    }
}

/// Resolves the topmost visible row from an unordered set of visible ids.
///
/// `onScrollTargetVisibilityChange` documents no ordering for the ids it
/// reports, so the topmost row is the one earliest in document order, not
/// `visibleIDs.first`. Ids absent from the index (never expected) sort last.
struct TopVisibleRowPolicy {
    let rowOrderIndex: [String: Int]

    func topRow(among visibleIDs: [String]) -> String? {
        visibleIDs.compactMap { id -> (order: Int, id: String)? in
            guard let order = rowOrderIndex[id] else { return nil }
            return (order, id)
        }
        .min { lhs, rhs in
            if lhs.order == rhs.order { return lhs.id < rhs.id }
            return lhs.order < rhs.order
        }?
        .id
    }
}

/// Observes the top visible row and reports it only after scrolling settles.
///
/// Both modifiers are pure observers: neither adds a body dependency nor
/// writes view state during a scroll, so the scroll view is never laid out
/// or repositioned mid-gesture. The row id is read at event time from the
/// tracker and handed to `onSettled` at `.idle` phase for persistence.
struct SettledScrollRowReporter: ViewModifier {
    let tracker: ScrollRowTracker
    let rowOrderIndex: [String: Int]
    let onSettled: @MainActor @Sendable (String?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { visibleIDs in
                    let policy = TopVisibleRowPolicy(rowOrderIndex: rowOrderIndex)
                    tracker.topRowID = policy.topRow(among: visibleIDs)
                }
                .onScrollPhaseChange { _, newPhase in
                    guard newPhase == .idle else { return }
                    onSettled(tracker.topRowID)
                }
        } else {
            // Both observers are iOS 18 / macOS 15 APIs. The app's iOS floor
            // is 18.4, so this branch is reachable only on macOS 14, where
            // this package builds for tests alone; no shipping surface
            // renders the diff pager there. Scroll-position persistence is
            // intentionally absent on that path.
            content
        }
    }
}

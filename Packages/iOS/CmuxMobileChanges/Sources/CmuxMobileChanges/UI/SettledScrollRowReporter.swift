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

/// Observes the top visible row and reports it only after scrolling settles.
///
/// Both modifiers are pure observers: neither adds a body dependency nor
/// writes view state during a scroll, so the scroll view is never laid out
/// or repositioned mid-gesture. The row id is read at event time from the
/// tracker and handed to `onSettled` at `.idle` phase for persistence.
struct SettledScrollRowReporter: ViewModifier {
    let tracker: ScrollRowTracker
    let onSettled: @MainActor @Sendable (String?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { visibleIDs in
                    guard let first = visibleIDs.first else { return }
                    tracker.topRowID = first
                }
                .onScrollPhaseChange { _, newPhase in
                    guard newPhase == .idle else { return }
                    onSettled(tracker.topRowID)
                }
        } else {
            content
        }
    }
}

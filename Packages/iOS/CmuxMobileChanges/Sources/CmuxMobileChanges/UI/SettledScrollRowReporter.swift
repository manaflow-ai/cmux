import SwiftUI

/// Reports the tracked scroll row only after the scroll view settles.
///
/// Persisting every row change while the finger is down or the view is
/// decelerating re-renders the pager mid-scroll; the bound
/// `scrollPosition(id:anchor:)` then re-anchors the tracked row on the next
/// layout pass, which cancels the remaining momentum. The row id must only be
/// read inside the phase callback so this modifier never adds a body
/// dependency on the continuously updating scroll position.
struct SettledScrollRowReporter: ViewModifier {
    @Binding var rowID: String?
    let onSettled: @MainActor @Sendable (String?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                guard newPhase == .idle else { return }
                onSettled(rowID)
            }
        } else {
            content
        }
    }
}

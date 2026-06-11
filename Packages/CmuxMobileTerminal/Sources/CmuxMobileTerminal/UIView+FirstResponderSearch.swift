#if canImport(UIKit)
import UIKit

extension UIView {
    /// Returns the first responder within this view's subtree (including `self`), or
    /// `nil` if no view in the subtree holds first responder.
    ///
    /// UIKit exposes no public "which view is first responder" API, but the question
    /// can be answered locally for a known subtree by a synchronous recursive walk:
    /// each view reports `isFirstResponder` for itself only, so the subtree must be
    /// searched to find a nested first responder (e.g. a `UITextField` deep inside a
    /// hosting controller's view). This drives the composer's open/close-vs-refocus
    /// decision on the terminal surface, so unlike the DEBUG-only
    /// ``CurrentResponderProbe`` it must be available in release and must not depend on
    /// a `sendAction(to: nil)` round-trip.
    ///
    /// The walk is depth-first and short-circuits on the first match. It runs on the
    /// main actor (UIKit), at the instant of a user tap, so it sees the live responder
    /// state with no SwiftUI-cycle lag.
    @MainActor
    func firstResponderInSubtree() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderInSubtree() {
                return found
            }
        }
        return nil
    }
}
#endif

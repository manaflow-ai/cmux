public import Foundation

/// A terminal hosted view whose reparent-focus side effects the layout
/// follow-up coordinator suppresses across a SwiftUI reparent, then clears once
/// the post-reparent layout attempt has settled.
///
/// `Workspace` keeps the set of pending-suppression views in
/// ``WorkspaceLayoutFollowUpCoordinator`` keyed by ``ObjectIdentifier``, but the
/// concrete view type (`GhosttySurfaceScrollView`) is an app-target AppKit class
/// that cannot cross into the package. This seam exposes only the four operations
/// the coordinator's suppression bookkeeping performs against each view, so the
/// package holds the views as `any WorkspaceReparentSuppressible` without naming
/// the app type. The app-target view conforms; the four members are lifted
/// one-for-one from the legacy `GhosttySurfaceScrollView` reparent-suppression
/// methods the `Workspace` follow-up bodies called inline.
@MainActor
public protocol WorkspaceReparentSuppressible: AnyObject {
    /// Begins suppressing this view's `becomeFirstResponder` side effects so a
    /// SwiftUI reparent does not steal focus from the newly split panel (legacy
    /// `GhosttySurfaceScrollView.suppressReparentFocus()`).
    func suppressReparentFocus()

    /// Stops suppressing this view's reparent-focus side effects (legacy
    /// `GhosttySurfaceScrollView.clearSuppressReparentFocus()`). Called when the
    /// follow-up ends or the view becomes ready.
    func clearSuppressReparentFocus()

    /// Whether this view's reparent-focus suppression can be released after a
    /// layout attempt, i.e. the reparent has settled (legacy
    /// `GhosttySurfaceScrollView.canClearPendingReparentFocusSuppressionAfterLayoutAttempt()`).
    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool
}

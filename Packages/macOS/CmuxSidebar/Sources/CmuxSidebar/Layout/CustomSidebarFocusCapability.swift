public import Foundation

/// The host's ability to focus a workspace, held by reference so it can be replaced in place.
///
/// The sidebar's SwiftUI mount hands down a fresh closure on every update — it captures the current
/// view state — while the registered handler must stay registered across those updates. Storing the
/// closure behind a reference keeps both true: the bridge captures this box once, and a new mount
/// swaps the closure inside it. Capturing the closure directly instead would freeze whichever one
/// happened to be current when the handler was installed, so a page could keep calling a stale
/// capability for the rest of the sidebar's life.
@MainActor
public final class CustomSidebarFocusCapability {
    /// Selects a workspace on the page's behalf and reports what happened.
    public var focus: @MainActor (UUID) -> CustomSidebarFocusStatus

    /// Creates a capability around an initial focus implementation.
    ///
    /// - Parameter focus: Performs the focus and reports the outcome.
    public init(focus: @escaping @MainActor (UUID) -> CustomSidebarFocusStatus) {
        self.focus = focus
    }
}

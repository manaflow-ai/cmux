public import SwiftUI
import Observation

/// Owns the feedback composer's presentation lifecycle for one window's
/// `ContentView`: the `isPresented` flag that drives the modal sheet plus the
/// request-to-present entry point.
///
/// Replaces the static `FeedbackComposerBridge`-flips-a-`@State`-flag pattern in
/// `ContentView`. The app constructs one coordinator per window root, binds the
/// sheet to ``isPresented``, and calls ``present()`` from the help-menu callback
/// and the `feedbackComposerRequested` notification observer. The composer view
/// itself stays owned by this package (``composerSheet()`` builds
/// ``SidebarFeedbackComposerSheet``), so the app target no longer references the
/// view type directly.
@MainActor
@Observable
public final class FeedbackComposerCoordinator {
    /// Whether the feedback composer sheet is currently presented. Bound to the
    /// `ContentView` `.sheet(isPresented:)` modifier; SwiftUI writes `false` back
    /// when the sheet dismisses.
    public var isPresented: Bool

    /// Creates a coordinator with the composer initially dismissed.
    public init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    /// Requests that the feedback composer be presented.
    ///
    /// The flag flip is deferred to the next main-runloop turn to preserve the
    /// app's original behavior (the lifted `ContentView.presentFeedbackComposer`
    /// wrapped the assignment in `DispatchQueue.main.async`): when the present
    /// request originates inside the `feedbackComposerRequested` notification
    /// dispatch, deferring lets that notification cycle complete before the sheet
    /// mounts. Modernizing this off `DispatchQueue.main.async` is a separate,
    /// behavior-affecting change and is intentionally not done in this lift.
    public func present() {
        DispatchQueue.main.async { [self] in
            isPresented = true
        }
    }

    /// Builds the package-owned feedback composer view to host inside the
    /// `ContentView` sheet closure. Keeps the concrete view type encapsulated in
    /// `CmuxFeedback`.
    public func composerSheet() -> some View {
        SidebarFeedbackComposerSheet()
    }
}

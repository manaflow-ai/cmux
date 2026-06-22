public import Foundation

/// A cancellable handle for the layout-follow-up event observers the host
/// installs (the `NSWindow.didUpdate` / terminal-ready / portal-visibility /
/// first-responder `NotificationCenter` watches plus the pane-tree panels
/// observation). Holding it keeps the watches armed; ``cancel()`` removes every
/// observer.
///
/// The host owns the literal `NotificationCenter.addObserver` calls (their names
/// are app-target `Notification.Name` constants the package cannot reach) and the
/// `paneTree` panels observation; it returns this handle so
/// ``WorkspaceLayoutFollowUpCoordinator`` owns the *lifetime* of that
/// registration without naming the app constants. Cancellation is idempotent and
/// runs the host-supplied teardown closure exactly once.
@MainActor
public final class WorkspaceLayoutFollowUpObservation {
    private var teardown: (() -> Void)?

    /// Creates a handle wrapping the host's teardown closure (removes the
    /// `NotificationCenter` observers and cancels the panels observation).
    public init(teardown: @escaping () -> Void) {
        self.teardown = teardown
    }

    /// Removes every layout-follow-up observer. Idempotent.
    public func cancel() {
        let teardown = teardown
        self.teardown = nil
        teardown?()
    }
}

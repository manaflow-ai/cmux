/// Action closure the web-content recovery overlay invokes when the reload
/// button is tapped.
///
/// `onReload` runs the app-side recovery path (`recoverTerminatedWebContent`).
/// The closure is non-isolated to match the overlay's SwiftUI `Button` action
/// shape; the app-side forwarder forms it in its main-actor view context.
public struct BrowserWebContentRecoveryActions {
    /// Recover the terminated web content (reload the panel).
    public var onReload: () -> Void

    /// Creates the web-content recovery action bundle.
    public init(onReload: @escaping () -> Void) {
        self.onReload = onReload
    }
}

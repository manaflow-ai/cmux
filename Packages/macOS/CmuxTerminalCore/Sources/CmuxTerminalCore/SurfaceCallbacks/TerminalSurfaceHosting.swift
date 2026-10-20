public import Foundation

/// The view side of the runtime callback seam.
///
/// Implemented by the app's terminal surface view so
/// ``GhosttySurfaceCallbackContext`` can fall back to the view's tab identity
/// and currently attached surface model when the model reference has already
/// been released, without importing the view layer.
public protocol TerminalSurfaceHosting: AnyObject {
    /// The workspace tab the view currently belongs to, if known.
    var hostedTabId: UUID? { get }

    /// The surface model currently attached to the view, if any.
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { get }
}

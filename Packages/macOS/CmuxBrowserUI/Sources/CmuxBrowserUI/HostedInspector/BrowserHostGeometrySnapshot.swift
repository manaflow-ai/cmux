public import Foundation

/// An equatable snapshot of a browser portal host view's geometry, used to
/// detect when a geometry-change callback actually needs to fire.
///
/// The host view records the last emitted snapshot and compares the current one
/// against it; equal snapshots are skipped so `setFrameOrigin`/`setFrameSize`
/// churn during a divider drag does not cascade redundant portal syncs. The
/// `superviewID`/`windowNumber` identity components are captured as plain value
/// types (`ObjectIdentifier`/`Int`) so the snapshot holds no live view state.
public struct BrowserHostGeometrySnapshot: Equatable {
    /// The host view's frame in its superview's coordinate space.
    public let frame: CGRect
    /// The host view's bounds.
    public let bounds: CGRect
    /// The number of the window the host view is in, or `nil` when unhosted.
    public let windowNumber: Int?
    /// The identity of the host view's current superview, or `nil` when detached.
    public let superviewID: ObjectIdentifier?

    /// Creates a geometry snapshot from the host view's current geometry and
    /// hosting identity.
    public init(
        frame: CGRect,
        bounds: CGRect,
        windowNumber: Int?,
        superviewID: ObjectIdentifier?
    ) {
        self.frame = frame
        self.bounds = bounds
        self.windowNumber = windowNumber
        self.superviewID = superviewID
    }
}

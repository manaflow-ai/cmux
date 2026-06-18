public import Foundation

/// The pre-parsed inputs for `surface.reorder`, lifted from the legacy
/// `v2SurfaceReorder` body's param parsing.
///
/// The coordinator validates that exactly one of `index` / `before_surface_id` /
/// `after_surface_id` is present (returning `invalid_params` itself); the app
/// resolves the surface and anchors and reorders within the pane.
public struct ControlSurfaceReorderInputs: Sendable, Equatable {
    /// The explicit target `index`, or `nil`.
    public let index: Int?
    /// The `before_surface_id` anchor, or `nil`.
    public let beforeSurfaceID: UUID?
    /// The `after_surface_id` anchor, or `nil`.
    public let afterSurfaceID: UUID?

    /// Creates reorder inputs.
    ///
    /// - Parameters:
    ///   - index: The explicit target index.
    ///   - beforeSurfaceID: The before anchor.
    ///   - afterSurfaceID: The after anchor.
    public init(index: Int?, beforeSurfaceID: UUID?, afterSurfaceID: UUID?) {
        self.index = index
        self.beforeSurfaceID = beforeSurfaceID
        self.afterSurfaceID = afterSurfaceID
    }
}

public import Foundation

/// The target of a focused-browser action (`browser.devtools.toggle`,
/// `browser.console.show`, `browser.focus_mode.set`, `browser.zoom.set`),
/// mirroring the legacy `v2ResolveBrowserPanelForFocusedAction` inputs: a
/// SUPPLIED `surface_id` is authoritative (even when unresolvable), while a
/// genuinely absent one falls back to the focused/sole browser.
public struct ControlBrowserFocusedActionTarget: Sendable, Equatable {
    /// Whether a non-null `surface_id` param was present at all.
    public let hasSurfaceParam: Bool
    /// The resolved `surface_id`, if it parsed/resolved.
    public let surfaceID: UUID?

    /// Creates a focused-action target.
    ///
    /// - Parameters:
    ///   - hasSurfaceParam: Whether a non-null `surface_id` param was present.
    ///   - surfaceID: The resolved `surface_id`, if any.
    public init(hasSurfaceParam: Bool, surfaceID: UUID?) {
        self.hasSurfaceParam = hasSurfaceParam
        self.surfaceID = surfaceID
    }
}

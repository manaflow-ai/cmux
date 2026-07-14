public import Observation

/// The single source of truth for one browser surface's automation viewport.
@MainActor
@Observable
public final class BrowserViewportModel {
    /// The requested logical viewport, or `nil` when pane geometry is authoritative.
    public private(set) var viewport: BrowserViewport?

    /// Creates a viewport model.
    ///
    /// - Parameter viewport: Initial logical viewport, or `nil` for native pane sizing.
    public init(viewport: BrowserViewport? = nil) {
        self.viewport = viewport
    }

    /// Replaces the requested viewport.
    ///
    /// - Parameter viewport: New logical viewport, or `nil` to restore native sizing.
    /// - Returns: `true` when the viewport changed.
    @discardableResult
    public func setViewport(_ viewport: BrowserViewport?) -> Bool {
        guard self.viewport != viewport else { return false }
        self.viewport = viewport
        return true
    }
}

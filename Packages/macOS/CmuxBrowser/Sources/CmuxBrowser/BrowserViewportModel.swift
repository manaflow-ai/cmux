public import CoreGraphics
public import Observation

/// The single source of truth for one browser surface's automation viewport.
@MainActor
@Observable
public final class BrowserViewportModel {
    /// The requested logical viewport, or `nil` when pane geometry is authoritative.
    public private(set) var viewport: BrowserViewport?

    /// The requested viewport, including one temporarily suspended while WebKit owns geometry.
    public var requestedViewport: BrowserViewport? {
        viewport ?? suspendedViewport
    }

    private var suspendedViewport: BrowserViewport?

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
        guard self.viewport != viewport || suspendedViewport != nil else { return false }
        self.viewport = viewport
        suspendedViewport = nil
        return true
    }

    /// Temporarily clears active emulation while an external WebKit presentation owns geometry.
    ///
    /// - Returns: `true` when an active emulated viewport was suspended.
    @discardableResult
    public func suspendForExternalGeometry() -> Bool {
        guard suspendedViewport == nil, let viewport else { return false }
        suspendedViewport = viewport
        self.viewport = nil
        return true
    }

    /// Restores the viewport suspended for external WebKit geometry ownership.
    ///
    /// - Returns: The restored viewport, or `nil` when there was no suspended viewport.
    @discardableResult
    public func resumeAfterExternalGeometry() -> BrowserViewport? {
        guard viewport == nil, let suspendedViewport else { return nil }
        self.suspendedViewport = nil
        viewport = suspendedViewport
        return suspendedViewport
    }

    /// Clears emulation and returns native geometry for an attached inspector transition.
    ///
    /// - Parameters:
    ///   - containerBounds: The bounds of the presentation container that owns the inspector split.
    ///   - pageZoom: Current WebKit page zoom.
    /// - Returns: Native geometry for the presentation container, or `nil` when already native.
    @discardableResult
    public func resetForAttachedInspector(
        containerBounds: CGRect,
        pageZoom: Double
    ) -> BrowserViewportLayout? {
        guard setViewport(nil) else { return nil }
        return BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: nil,
            pageZoom: pageZoom
        )
    }
}

public import CoreGraphics

/// The AppKit frame/bounds projection for a logical browser viewport.
public struct BrowserViewportLayout: Equatable, Sendable {
    /// How the WebView derives its logical viewport.
    public enum Mode: String, Equatable, Sendable {
        /// The logical viewport follows the native pane geometry.
        case native

        /// The requested logical viewport is aspect-fitted inside the pane.
        case emulated
    }

    /// The active viewport mode.
    public let mode: Mode

    /// The WebView frame in its pane host's coordinate system.
    public let frame: CGRect

    /// The logical viewport bounds exposed to automation in CSS pixels.
    public let bounds: CGRect

    /// The AppKit bounds assigned to the WebView after accounting for page zoom.
    public let webViewBounds: CGRect

    /// Uniform scale from logical CSS points to displayed AppKit points.
    public let scale: Double

    /// Projects an optional logical viewport into an existing pane without resizing the pane.
    ///
    /// - Parameters:
    ///   - containerBounds: Available pane bounds in the host view's coordinate system.
    ///   - viewport: Requested logical viewport, or `nil` for native pane sizing.
    ///   - pageZoom: Current WebKit page zoom. Invalid values fall back to `1`.
    public init(containerBounds: CGRect, viewport: BrowserViewport?, pageZoom: Double = 1) {
        guard let viewport else {
            mode = .native
            frame = containerBounds
            bounds = CGRect(origin: .zero, size: containerBounds.size)
            webViewBounds = bounds
            scale = containerBounds.width > 0 && containerBounds.height > 0 ? 1 : 0
            return
        }

        mode = .emulated
        bounds = CGRect(origin: .zero, size: viewport.size)
        let resolvedPageZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        webViewBounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: viewport.size.width * resolvedPageZoom,
                height: viewport.size.height * resolvedPageZoom
            )
        )

        guard containerBounds.width.isFinite,
              containerBounds.height.isFinite,
              containerBounds.width > 0,
              containerBounds.height > 0 else {
            frame = CGRect(origin: containerBounds.origin, size: .zero)
            scale = 0
            return
        }

        let resolvedScale = min(
            containerBounds.width / viewport.size.width,
            containerBounds.height / viewport.size.height
        )
        let displaySize = CGSize(
            width: viewport.size.width * resolvedScale,
            height: viewport.size.height * resolvedScale
        )
        frame = CGRect(
            x: containerBounds.midX - displaySize.width / 2,
            y: containerBounds.midY - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        )
        scale = resolvedScale
    }
}

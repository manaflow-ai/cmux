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

    /// The WebView bounds that WebKit exposes as its logical viewport.
    public let bounds: CGRect

    /// Uniform scale from logical CSS points to displayed AppKit points.
    public let scale: Double

    /// Projects an optional logical viewport into an existing pane without resizing the pane.
    ///
    /// - Parameters:
    ///   - containerBounds: Available pane bounds in the host view's coordinate system.
    ///   - viewport: Requested logical viewport, or `nil` for native pane sizing.
    public init(containerBounds: CGRect, viewport: BrowserViewport?) {
        guard let viewport else {
            mode = .native
            frame = containerBounds
            bounds = CGRect(origin: .zero, size: containerBounds.size)
            scale = containerBounds.width > 0 && containerBounds.height > 0 ? 1 : 0
            return
        }

        mode = .emulated
        bounds = CGRect(origin: .zero, size: viewport.size)

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

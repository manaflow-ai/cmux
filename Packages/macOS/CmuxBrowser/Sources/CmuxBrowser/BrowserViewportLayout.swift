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
    ///   - renderLimits: Maximum WebKit geometry allowed for an emulated viewport.
    public init?(
        containerBounds: CGRect,
        viewport: BrowserViewport?,
        pageZoom: Double = 1,
        renderLimits: BrowserViewportRenderLimits = .standard
    ) {
        let resolvedPageZoom = pageZoom.isFinite && pageZoom > 0 ? pageZoom : 1
        if let viewport,
           !renderLimits.supports(viewport: viewport, pageZoom: resolvedPageZoom) {
            return nil
        }
        guard let viewport else {
            mode = .native
            frame = containerBounds
            // WKWebView quantizes its AppKit viewport to whole points before applying
            // pageZoom. Mirror that ordering so native viewport RPCs report the same
            // CSS dimensions as window.innerWidth/window.innerHeight for split widths
            // such as 379.5 points.
            let quantizedContainerSize = CGSize(
                width: containerBounds.width.rounded(.down),
                height: containerBounds.height.rounded(.down)
            )
            bounds = CGRect(
                origin: .zero,
                size: CGSize(
                    width: quantizedContainerSize.width / resolvedPageZoom,
                    height: quantizedContainerSize.height / resolvedPageZoom
                )
            )
            webViewBounds = CGRect(origin: .zero, size: containerBounds.size)
            scale = containerBounds.width > 0 && containerBounds.height > 0
                ? resolvedPageZoom
                : 0
            return
        }

        mode = .emulated
        bounds = CGRect(origin: .zero, size: viewport.size)
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

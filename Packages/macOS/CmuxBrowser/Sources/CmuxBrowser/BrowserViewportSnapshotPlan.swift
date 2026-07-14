public import CoreGraphics

/// Plans an exact CSS-pixel screenshot without asking WebKit for excess backing pixels.
public struct BrowserViewportSnapshotPlan: Equatable, Sendable {
    /// Maximum physical-pixel area allowed for one emulated viewport screenshot.
    public static let maximumOutputPixelCount =
        BrowserViewport.maximumDimension * BrowserViewport.maximumDimension

    /// Width passed to WebKit's snapshot configuration in AppKit points.
    public let snapshotPointWidth: Double

    /// Exact bitmap dimensions exported by browser automation.
    public let outputPixelSize: CGSize

    /// Number of pixels in the normalized output bitmap.
    public let outputPixelCount: Int

    /// Creates a snapshot plan for an emulated viewport and display scale.
    ///
    /// - Parameters:
    ///   - viewport: Logical CSS viewport that the screenshot must represent.
    ///   - backingScaleFactor: Pixels per AppKit point for the WebView's window.
    public init(viewport: BrowserViewport, backingScaleFactor: Double) {
        let resolvedScale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        snapshotPointWidth = Double(viewport.width) / resolvedScale
        outputPixelSize = viewport.size
        outputPixelCount = viewport.width * viewport.height
    }
}

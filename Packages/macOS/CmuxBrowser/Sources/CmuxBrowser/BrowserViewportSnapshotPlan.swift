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

    /// Creates a bounded snapshot plan for a CSS-pixel output size.
    ///
    /// This initializer supports native page-zoom captures, whose CSS viewport can differ from
    /// the WebView's AppKit bounds even when no emulated viewport is active.
    ///
    /// - Parameters:
    ///   - outputPixelSize: Desired exported bitmap dimensions in CSS pixels.
    ///   - backingScaleFactor: Pixels per AppKit point for the WebView's window.
    public init?(outputPixelSize: CGSize, backingScaleFactor: Double) {
        guard outputPixelSize.width.isFinite,
              outputPixelSize.height.isFinite,
              outputPixelSize.width > 0,
              outputPixelSize.height > 0 else {
            return nil
        }

        let pixelWidth = outputPixelSize.width.rounded(.up)
        let pixelHeight = outputPixelSize.height.rounded(.up)
        guard pixelWidth <= Double(Int.max),
              pixelHeight <= Double(Int.max) else {
            return nil
        }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, pixelCount <= Self.maximumOutputPixelCount else {
            return nil
        }

        let resolvedScale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        snapshotPointWidth = pixelWidth / resolvedScale
        self.outputPixelSize = CGSize(width: width, height: height)
        outputPixelCount = pixelCount
    }

    /// Returns whether an existing image representation already has the planned pixel dimensions.
    public func canReuseSourcePixels(_ sourcePixelSize: CGSize, tolerance: Double = 0.5) -> Bool {
        guard sourcePixelSize.width.isFinite,
              sourcePixelSize.height.isFinite,
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }
        return abs(sourcePixelSize.width - outputPixelSize.width) <= tolerance
            && abs(sourcePixelSize.height - outputPixelSize.height) <= tolerance
    }
}

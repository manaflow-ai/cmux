public import AppKit

/// Conservatively checks whether stable, high-contrast DOM text appears in a browser snapshot.
///
/// The verifier accepts inconclusive frames and reports a mismatch only when
/// multiple stable text probes each map to a uniform pixel region matching the
/// opaque solid background expected by the DOM.
public struct BrowserScreenshotFrameVerifier: Sendable {
    private let minimumMismatchCount: Int
    private let maximumProbeCount: Int
    private let rectTolerance: CGFloat
    private let uniformityTolerance: CGFloat
    private let minimumForegroundContrast: CGFloat
    private let maximumSamplesPerProbe: Int

    /// Creates a conservative verifier with bounded probe and pixel work.
    ///
    /// - Parameters:
    ///   - minimumMismatchCount: Distinct viewport cells with stable uniform probes
    ///     required to reject a frame.
    ///   - maximumProbeCount: Maximum stable probes evaluated per frame.
    ///   - rectTolerance: Maximum CSS-point drift allowed between probe collections.
    ///   - uniformityTolerance: Maximum normalized channel difference treated as uniform
    ///     and as matching the DOM-derived solid background.
    ///   - minimumForegroundContrast: Minimum normalized text/background channel distance.
    ///   - maximumSamplesPerProbe: Approximate upper bound on sampled pixels per probe.
    public init(
        minimumMismatchCount: Int = 2,
        maximumProbeCount: Int = 12,
        rectTolerance: CGFloat = 1,
        uniformityTolerance: CGFloat = 16.0 / 255.0,
        minimumForegroundContrast: CGFloat = 48.0 / 255.0,
        maximumSamplesPerProbe: Int = 1_024
    ) {
        self.minimumMismatchCount = minimumMismatchCount
        self.maximumProbeCount = maximumProbeCount
        self.rectTolerance = rectTolerance
        self.uniformityTolerance = uniformityTolerance
        self.minimumForegroundContrast = minimumForegroundContrast
        self.maximumSamplesPerProbe = max(1, maximumSamplesPerProbe)
    }

    /// Compares stable DOM evidence around a snapshot with the captured pixels.
    ///
    /// - Parameters:
    ///   - before: DOM probes collected immediately before the snapshot.
    ///   - after: DOM probes collected immediately after the snapshot.
    ///   - pixels: Snapshot pixel source in top-left-origin coordinates.
    /// - Returns: A mismatch only when conservative evidence meets the configured threshold.
    public func verify(
        before: BrowserScreenshotProbeSet,
        after: BrowserScreenshotProbeSet,
        pixels: any BrowserScreenshotPixelSource
    ) -> BrowserScreenshotVerificationOutcome {
        guard valid(size: before.viewportSize),
              valid(size: after.viewportSize),
              valid(size: pixels.pixelSize),
              approximatelyEqual(before.viewportSize, after.viewportSize),
              hasUniformScale(
                  viewportSize: after.viewportSize,
                  pixelSize: pixels.pixelSize
              ) else {
            return .accepted
        }

        let afterByIdentifier = Dictionary(
            after.probes.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let stableProbes = before.probes.lazy.compactMap { probe -> BrowserScreenshotProbe? in
            guard let current = afterByIdentifier[probe.identifier],
                  probe.text == current.text,
                  approximatelyEqual(probe.rect, current.rect),
                  approximatelyEqual(probe.foreground, current.foreground),
                  approximatelyEqual(probe.background, current.background) else {
                return nil
            }
            return current
        }

        var mismatches: [BrowserScreenshotProbe] = []
        var mismatchCells: Set<Int> = []
        for probe in stableProbes.prefix(maximumProbeCount) {
            guard probe.foreground.distance(from: probe.background) >= minimumForegroundContrast,
                  pixelsAreUniform(
                      probe,
                      viewportSize: after.viewportSize,
                      pixels: pixels
                  ) else {
                continue
            }
            mismatches.append(probe)
            let cell = evidenceCell(for: probe.rect, viewportSize: after.viewportSize)
            mismatchCells.insert(cell)
        }
        if mismatchCells.count >= minimumMismatchCount, let first = mismatches.first {
            return .mismatch(probe: first, count: mismatches.count)
        }
        return .accepted
    }

    /// A painted glyph introduces color or alpha variation inside its range.
    /// A missing glyph reveals the solid CSS background expected by the DOM or
    /// a transparent compositor hole where the DOM requires opaque content.
    /// A different uniform color is inconclusive because an unobservable
    /// pointer-events-none overlay may legitimately cover the text.
    private func pixelsAreUniform(
        _ probe: BrowserScreenshotProbe,
        viewportSize: NSSize,
        pixels: any BrowserScreenshotPixelSource
    ) -> Bool {
        guard probe.rect.width > 0,
              probe.rect.height > 0,
              probe.rect.minX >= 0,
              probe.rect.minY >= 0,
              probe.rect.maxX <= viewportSize.width,
              probe.rect.maxY <= viewportSize.height else {
            return false
        }

        let pixelRect = NSRect(
            x: probe.rect.minX / viewportSize.width * pixels.pixelSize.width,
            y: probe.rect.minY / viewportSize.height * pixels.pixelSize.height,
            width: probe.rect.width / viewportSize.width * pixels.pixelSize.width,
            height: probe.rect.height / viewportSize.height * pixels.pixelSize.height
        )
        let minX = max(0, Int(pixelRect.minX.rounded(.down)))
        let minY = max(0, Int(pixelRect.minY.rounded(.down)))
        let maxX = min(
            Int(pixels.pixelSize.width.rounded(.down)) - 1,
            Int(pixelRect.maxX.rounded(.up)) - 1
        )
        let maxY = min(
            Int(pixels.pixelSize.height.rounded(.down)) - 1,
            Int(pixelRect.maxY.rounded(.up)) - 1
        )
        guard minX <= maxX, minY <= maxY else { return false }

        let sampleArea = (maxX - minX + 1) * (maxY - minY + 1)
        let stride = max(
            1,
            Int(ceil(sqrt(Double(sampleArea) / Double(maximumSamplesPerProbe))))
        )
        let sampleRect = NSRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard let colors = pixels.colors(in: sampleRect, stride: stride) else {
            return false
        }
        var referenceColor: BrowserScreenshotRGBA?
        for color in colors {
            guard let referenceColor else {
                referenceColor = color
                continue
            }
            if color.distance(from: referenceColor) > uniformityTolerance {
                return false
            }
        }
        guard let referenceColor else { return false }
        return referenceColor.alpha <= uniformityTolerance
            || referenceColor.distance(from: probe.background) <= uniformityTolerance
    }

    /// Maps a probe to one of sixteen viewport cells for independent mismatch evidence.
    private func evidenceCell(for rect: NSRect, viewportSize: NSSize) -> Int {
        let column = min(3, max(0, Int(rect.midX / viewportSize.width * 4)))
        let row = min(3, max(0, Int(rect.midY / viewportSize.height * 4)))
        return row * 4 + column
    }

    /// Returns whether a size is finite and nonempty.
    private func valid(size: NSSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    /// Rejects coordinate mappings that would scale CSS axes differently.
    private func hasUniformScale(viewportSize: NSSize, pixelSize: NSSize) -> Bool {
        let widthScale = pixelSize.width / viewportSize.width
        let heightScale = pixelSize.height / viewportSize.height
        let widthSkew = abs(pixelSize.width - viewportSize.width * heightScale)
        let heightSkew = abs(pixelSize.height - viewportSize.height * widthScale)
        return widthScale > 0
            && heightScale > 0
            && widthSkew <= 1
            && heightSkew <= 1
    }

    /// Returns whether two viewport sizes are within the configured CSS-point tolerance.
    private func approximatelyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) <= rectTolerance
            && abs(lhs.height - rhs.height) <= rectTolerance
    }

    /// Returns whether two probe rectangles are within the configured CSS-point tolerance.
    private func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= rectTolerance
            && abs(lhs.minY - rhs.minY) <= rectTolerance
            && abs(lhs.width - rhs.width) <= rectTolerance
            && abs(lhs.height - rhs.height) <= rectTolerance
    }

    /// Returns whether two DOM-derived colors differ by at most one 8-bit channel step.
    private func approximatelyEqual(
        _ lhs: BrowserScreenshotRGBA,
        _ rhs: BrowserScreenshotRGBA
    ) -> Bool {
        lhs.distance(from: rhs) <= 1.0 / 255.0
            && abs(lhs.alpha - rhs.alpha) <= 1.0 / 255.0
    }
}

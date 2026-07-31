public import AppKit

/// Conservatively checks whether stable, high-contrast DOM text appears in a browser snapshot.
///
/// The verifier accepts inconclusive frames and reports a mismatch only when
/// multiple stable text probes each map to a uniform pixel region matching the
/// opaque solid background expected by the DOM.
public struct BrowserScreenshotFrameVerifier: Sendable {
    /// A normalized pixel color used by the frame verifier.
    public struct RGBA: Equatable, Sendable {
        /// Red component in the source bitmap's color space, normalized to `0...1`.
        public let red: CGFloat
        /// Green component in the source bitmap's color space, normalized to `0...1`.
        public let green: CGFloat
        /// Blue component in the source bitmap's color space, normalized to `0...1`.
        public let blue: CGFloat
        /// Alpha component, normalized to `0...1`.
        public let alpha: CGFloat

        /// Opaque black.
        public static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        /// Opaque white.
        public static let white = RGBA(red: 1, green: 1, blue: 1, alpha: 1)

        /// Creates a normalized color.
        ///
        /// - Parameters:
        ///   - red: Red component in the source bitmap's color space.
        ///   - green: Green component in the source bitmap's color space.
        ///   - blue: Blue component in the source bitmap's color space.
        ///   - alpha: Alpha component.
        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// Returns the largest normalized channel difference from another color.
        func distance(from other: RGBA) -> CGFloat {
            max(
                abs(red - other.red),
                abs(green - other.green),
                abs(blue - other.blue),
                abs(alpha - other.alpha)
            )
        }
    }

    /// DOM evidence for one visible text glyph.
    public struct Probe: Equatable, Sendable {
        /// Stable, opaque DOM-path identifier for the probed glyph.
        public let identifier: String
        /// Text-node content used only to confirm stability across capture.
        ///
        /// Callers must not include this value in logs or user-visible errors.
        public let text: String
        /// A single visible glyph rect in CSS viewport coordinates, with a top-left origin.
        public let rect: NSRect
        /// The text color after compositing CSS color alpha over ``background``.
        public let foreground: RGBA
        /// The opaque solid background color under the glyph.
        public let background: RGBA

        /// Creates a text probe collected from the DOM.
        ///
        /// - Parameters:
        ///   - identifier: Stable, opaque identity shared by pre- and post-capture probes.
        ///   - text: Text used only to determine whether the probe stayed stable.
        ///   - rect: Visible glyph rectangle in CSS viewport coordinates.
        ///   - foreground: Text color composited over `background`.
        ///   - background: Opaque solid color beneath the glyph.
        public init(
            identifier: String,
            text: String,
            rect: NSRect,
            foreground: RGBA,
            background: RGBA
        ) {
            self.identifier = identifier
            self.text = text
            self.rect = rect
            self.foreground = foreground
            self.background = background
        }
    }

    /// A bounded collection of probes for one viewport state.
    public struct ProbeSet: Equatable, Sendable {
        /// CSS viewport size with a top-left origin.
        public let viewportSize: NSSize
        /// Candidate text probes distributed across the viewport.
        public let probes: [Probe]

        /// Creates a probe set for a viewport state.
        ///
        /// - Parameters:
        ///   - viewportSize: CSS viewport size represented by the probes.
        ///   - probes: Bounded text probes distributed across the viewport.
        public init(viewportSize: NSSize, probes: [Probe]) {
            self.viewportSize = viewportSize
            self.probes = probes
        }
    }

    /// Supplies snapshot colors in top-left-origin pixel coordinates.
    public protocol PixelSource {
        /// Pixel dimensions of the snapshot.
        var pixelSize: NSSize { get }
        /// Returns the pixel color at a top-left-origin point.
        ///
        /// - Parameter point: Pixel coordinate to sample.
        /// - Returns: A normalized color, or `nil` when the point cannot be sampled.
        func color(at point: NSPoint) -> RGBA?
    }

    /// Conservative verification result for one snapshot.
    public enum Outcome: Equatable, Sendable {
        /// The snapshot is valid or the available evidence is inconclusive.
        case accepted
        /// At least the configured minimum number of stable probes matched their backgrounds.
        ///
        /// The associated probe identifies the first mismatching rectangle;
        /// `count` is the total number of mismatches found in the bounded set.
        case mismatch(probe: Probe, count: Int)
    }

    private let minimumMismatchCount: Int
    private let maximumProbeCount: Int
    private let rectTolerance: CGFloat
    private let uniformityTolerance: CGFloat
    private let minimumForegroundContrast: CGFloat
    private let maximumSamplesPerProbe: Int

    /// Creates a conservative verifier with bounded probe and pixel work.
    ///
    /// - Parameters:
    ///   - minimumMismatchCount: Stable uniform probes required to reject a frame.
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
        before: ProbeSet,
        after: ProbeSet,
        pixels: any PixelSource
    ) -> Outcome {
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
        let stableProbes = before.probes.lazy.compactMap { probe -> Probe? in
            guard let current = afterByIdentifier[probe.identifier],
                  probe.text == current.text,
                  approximatelyEqual(probe.rect, current.rect),
                  approximatelyEqual(probe.foreground, current.foreground),
                  approximatelyEqual(probe.background, current.background) else {
                return nil
            }
            return current
        }

        var mismatches: [Probe] = []
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
    /// A missing glyph reveals the solid CSS background expected by the DOM.
    /// A different uniform color is inconclusive because an unobservable
    /// pointer-events-none overlay may legitimately cover the text.
    private func pixelsAreUniform(
        _ probe: Probe,
        viewportSize: NSSize,
        pixels: any PixelSource
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
        var referenceColor: RGBA?
        for y in Swift.stride(from: minY, through: maxY, by: stride) {
            for x in Swift.stride(from: minX, through: maxX, by: stride) {
                guard let color = pixels.color(
                    at: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                ) else {
                    return false
                }
                guard let referenceColor else {
                    referenceColor = color
                    continue
                }
                if color.distance(from: referenceColor) > uniformityTolerance {
                    return false
                }
            }
        }
        guard let referenceColor else { return false }
        return referenceColor.distance(from: probe.background) <= uniformityTolerance
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
        let largestScale = max(widthScale, heightScale)
        return largestScale > 0
            && abs(widthScale - heightScale) / largestScale <= 0.01
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
    private func approximatelyEqual(_ lhs: RGBA, _ rhs: RGBA) -> Bool {
        lhs.distance(from: rhs) <= 1.0 / 255.0
            && abs(lhs.alpha - rhs.alpha) <= 1.0 / 255.0
    }
}

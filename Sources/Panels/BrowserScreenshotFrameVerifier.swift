import AppKit

/// Conservatively checks whether stable, high-contrast DOM text appears in a browser snapshot.
struct BrowserScreenshotFrameVerifier {
    struct RGBA: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        static let white = RGBA(red: 1, green: 1, blue: 1, alpha: 1)

        func distance(from other: RGBA) -> CGFloat {
            max(
                abs(red - other.red),
                abs(green - other.green),
                abs(blue - other.blue),
                abs(alpha - other.alpha)
            )
        }
    }

    struct Probe: Equatable {
        let identifier: String
        let text: String
        /// A single visible glyph rect in CSS viewport coordinates, with a top-left origin.
        let rect: NSRect
        /// The text color after compositing CSS color alpha over ``background``.
        let foreground: RGBA
        /// The opaque solid background color under the glyph.
        let background: RGBA
    }

    struct ProbeSet: Equatable {
        let viewportSize: NSSize
        let probes: [Probe]
    }

    /// Supplies snapshot colors in top-left-origin pixel coordinates.
    protocol PixelSource {
        var pixelSize: NSSize { get }
        func color(at point: NSPoint) -> RGBA?
    }

    enum Outcome: Equatable {
        case accepted
        case mismatch(probe: Probe, count: Int)
    }

    private let minimumMismatchCount: Int
    private let maximumProbeCount: Int
    private let rectTolerance: CGFloat
    private let uniformityTolerance: CGFloat
    private let minimumForegroundContrast: CGFloat
    private let maximumSamplesPerProbe: Int

    init(
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

    func verify(
        before: ProbeSet,
        after: ProbeSet,
        pixels: any PixelSource
    ) -> Outcome {
        guard valid(size: before.viewportSize),
              valid(size: after.viewportSize),
              valid(size: pixels.pixelSize),
              approximatelyEqual(before.viewportSize, after.viewportSize) else {
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
        }
        if mismatches.count >= minimumMismatchCount, let first = mismatches.first {
            return .mismatch(probe: first, count: mismatches.count)
        }
        return .accepted
    }

    /// A painted glyph introduces color or alpha variation inside its range.
    /// A missing layer stays uniform even when it reveals a different solid
    /// color (or transparency) than the CSS background expected by the DOM.
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
        return referenceColor != nil
    }

    private func valid(size: NSSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    private func approximatelyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) <= rectTolerance
            && abs(lhs.height - rhs.height) <= rectTolerance
    }

    private func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= rectTolerance
            && abs(lhs.minY - rhs.minY) <= rectTolerance
            && abs(lhs.width - rhs.width) <= rectTolerance
            && abs(lhs.height - rhs.height) <= rectTolerance
    }

    private func approximatelyEqual(_ lhs: RGBA, _ rhs: RGBA) -> Bool {
        lhs.distance(from: rhs) <= 1.0 / 255.0
            && abs(lhs.alpha - rhs.alpha) <= 1.0 / 255.0
    }
}

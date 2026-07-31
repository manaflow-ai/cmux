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
                abs(blue - other.blue)
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
    private let backgroundTolerance: CGFloat
    private let minimumForegroundContrast: CGFloat
    private let sampleFractions: [NSPoint]

    init(
        minimumMismatchCount: Int = 2,
        maximumProbeCount: Int = 12,
        rectTolerance: CGFloat = 1,
        backgroundTolerance: CGFloat = 16.0 / 255.0,
        minimumForegroundContrast: CGFloat = 48.0 / 255.0
    ) {
        self.minimumMismatchCount = minimumMismatchCount
        self.maximumProbeCount = maximumProbeCount
        self.rectTolerance = rectTolerance
        self.backgroundTolerance = backgroundTolerance
        self.minimumForegroundContrast = minimumForegroundContrast
        self.sampleFractions = [
            NSPoint(x: 0.10, y: 0.20),
            NSPoint(x: 0.30, y: 0.20),
            NSPoint(x: 0.50, y: 0.20),
            NSPoint(x: 0.70, y: 0.20),
            NSPoint(x: 0.90, y: 0.20),
            NSPoint(x: 0.10, y: 0.40),
            NSPoint(x: 0.30, y: 0.40),
            NSPoint(x: 0.50, y: 0.40),
            NSPoint(x: 0.70, y: 0.40),
            NSPoint(x: 0.90, y: 0.40),
            NSPoint(x: 0.10, y: 0.60),
            NSPoint(x: 0.30, y: 0.60),
            NSPoint(x: 0.50, y: 0.60),
            NSPoint(x: 0.70, y: 0.60),
            NSPoint(x: 0.90, y: 0.60),
            NSPoint(x: 0.10, y: 0.80),
            NSPoint(x: 0.30, y: 0.80),
            NSPoint(x: 0.50, y: 0.80),
            NSPoint(x: 0.70, y: 0.80),
            NSPoint(x: 0.90, y: 0.80),
        ]
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
                  pixelsMatchOnlyBackground(
                      probe,
                      viewportSize: after.viewportSize,
                      pixels: pixels
                  ) else {
                continue
            }
            mismatches.append(probe)
            if mismatches.count >= minimumMismatchCount {
                return .mismatch(probe: mismatches[0], count: mismatches.count)
            }
        }
        return .accepted
    }

    private func pixelsMatchOnlyBackground(
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

        var sampledColor = false
        for fraction in sampleFractions {
            let cssPoint = NSPoint(
                x: probe.rect.minX + probe.rect.width * fraction.x,
                y: probe.rect.minY + probe.rect.height * fraction.y
            )
            let pixelPoint = NSPoint(
                x: cssPoint.x / viewportSize.width * pixels.pixelSize.width,
                y: cssPoint.y / viewportSize.height * pixels.pixelSize.height
            )
            guard let color = pixels.color(at: pixelPoint) else {
                return false
            }
            sampledColor = true
            if color.distance(from: probe.background) > backgroundTolerance {
                return false
            }
        }
        return sampledColor
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

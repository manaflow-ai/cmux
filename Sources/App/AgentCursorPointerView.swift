import AppKit

/// The exact Sky cursor geometry and cmux brand fill shared by the live pointer
/// and the standalone Computer Use helper icon.
private enum ComputerUseCursorArtwork {
    static func path() -> CGPath {
        let kite = CGMutablePath()
        kite.move(to: CGPoint(x: 0.68, y: 1.83))
        kite.addLine(to: CGPoint(x: 3.63, y: 9.78))
        kite.addQuadCurve(to: CGPoint(x: 5.3, y: 9.66), control: CGPoint(x: 4.67, y: 12.59))
        kite.addLine(to: CGPoint(x: 5.44, y: 9.01))
        kite.addQuadCurve(to: CGPoint(x: 9.01, y: 5.44), control: CGPoint(x: 6.08, y: 6.08))
        kite.addLine(to: CGPoint(x: 9.66, y: 5.3))
        kite.addQuadCurve(to: CGPoint(x: 9.78, y: 3.63), control: CGPoint(x: 12.59, y: 4.67))
        kite.addLine(to: CGPoint(x: 1.83, y: 0.68))
        kite.addQuadCurve(to: CGPoint(x: 0.68, y: 1.83), control: CGPoint(x: 0, y: 0))
        kite.closeSubpath()
        return kite
    }

    static func draw(
        in context: CGContext,
        scale: CGFloat,
        outlineColor: CGColor? = nil,
        outlineWidth: CGFloat = 0
    ) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let kite = path()

        if let outlineColor, outlineWidth > 0 {
            // The upstream asset uses `paint-order: stroke`, so its outline is
            // drawn first and remains outside the gradient fill.
            context.addPath(kite)
            context.setLineWidth(outlineWidth)
            context.setLineJoin(.round)
            context.setStrokeColor(outlineColor)
            context.strokePath()
        }

        context.saveGState()
        context.addPath(kite)
        context.clip()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(
                colorSpace: colorSpace,
                components: [0x12 / 255.0, 0xC7 / 255.0, 0xF5 / 255.0, 1.0]
            )!,
            CGColor(
                colorSpace: colorSpace,
                components: [0x2D / 255.0, 0x8C / 255.0, 0xFF / 255.0, 1.0]
            )!,
            CGColor(
                colorSpace: colorSpace,
                components: [0x6C / 255.0, 0x5C / 255.0, 0xFF / 255.0, 1.0]
            )!,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0.0, 0.5, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0.68, y: 0.68),
                end: CGPoint(x: 11.0, y: 11.0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
        context.restoreGState()
    }
}

/// Produces the helper's rounded app icon with the live cursor's exact shape
/// and gradient. The plate is rendered explicitly per appearance — a light
/// tile in Aqua, a dark tile in Dark Aqua — so the icon always matches the
/// effective cmux appearance (the cmux setting when overridden, the system
/// otherwise) instead of relying on a translucent plate over the backdrop.
@MainActor
enum ComputerUseHelperIconRenderer {
    private static let canvasSize = NSSize(width: 1_024, height: 1_024)
    private static let plateCornerRadius: CGFloat = 224
    private static let lightPlateColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)
    private static let darkPlateColor = NSColor(calibratedWhite: 0.17, alpha: 1.0)
    private static let cursorTranslation = CGPoint(x: 293.4, y: 293.4)
    private static let cursorScale: CGFloat = 44.8
    private static var cachedImages: [Bool: NSImage] = [:]

    static func image(darkMode: Bool? = nil) -> NSImage? {
        let isDark = darkMode ?? (
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
        if let cached = cachedImages[isDark] {
            return cached
        }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width),
                pixelsHigh: Int(canvasSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }
        bitmap.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let context = graphicsContext.cgContext
        let canvas = CGRect(origin: .zero, size: canvasSize)
        context.clear(canvas)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Core Graphics is y-up here; flip once so the shared SVG geometry
        // keeps the live cursor's up-left direction.
        context.saveGState()
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)

        let plate = CGPath(
            roundedRect: canvas,
            cornerWidth: plateCornerRadius,
            cornerHeight: plateCornerRadius,
            transform: nil
        )
        context.addPath(plate)
        context.setFillColor((isDark ? darkPlateColor : lightPlateColor).cgColor)
        context.fillPath()

        context.translateBy(x: cursorTranslation.x, y: cursorTranslation.y)
        ComputerUseCursorArtwork.draw(
            in: context,
            scale: cursorScale
        )
        context.restoreGState()

        let image = NSImage(size: canvasSize)
        image.addRepresentation(bitmap)
        image.cacheMode = .never
        image.isTemplate = false
        cachedImages[isDark] = image
        return image
    }
}

/// Draws the computer-use cursor: the Sky kite silhouette from cua PR #1, filled
/// with the cmux brand gradient (#12c7f5 -> #2d8cff -> #6c5cff) and a white
/// outline, as a stable AppKit view.
@MainActor
final class AgentCursorPointerView: NSView {
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // This is a decorative mirror of the real pointer. Exposing it makes
        // every animated frame change observable as an accessibility-tree update.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Scale from the Sky asset's 18.59-unit viewBox to view points. The kite
    /// silhouette occupies ~11.2 units of that box, so this renders a ~17pt cursor.
    private static let skyScale: CGFloat = 1.5

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The icon renderer calls this same path/gradient without an outline;
        // the live pointer keeps the upstream white stroke for contrast over apps.
        ComputerUseCursorArtwork.draw(
            in: context,
            scale: Self.skyScale,
            outlineColor: NSColor.white.cgColor,
            outlineWidth: 1.7
        )
    }
}

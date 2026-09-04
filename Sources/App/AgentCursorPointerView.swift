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
        width: CGFloat = 1,
        height: CGFloat = 1,
        roundness: CGFloat = 0,
        rotation: CGFloat = 0,
        outlineColor: CGColor? = nil,
        outlineWidth: CGFloat = 0
    ) {
        context.saveGState()
        let widthFactor = max(0.01, width)
        let heightFactor = max(0.01, height)
        let xScale = scale * widthFactor
        let yScale = scale * heightFactor
        let centerX = 0.4957769 + 10.6598503 / 2
        let centerY = 0.4957769 + 10.6598503 / 2
        // Match the logo lab transform: scale around the source center, then
        // apply rotation. Translation is supplied by the caller so the live
        // pointer can continue to use its own window coordinates.
        context.translateBy(x: centerX * xScale, y: centerY * yScale)
        context.rotate(by: rotation * .pi / 180)
        context.scaleBy(x: xScale, y: yScale)
        context.translateBy(x: -centerX, y: -centerY)
        let kite = path()

        let cornerRadius = max(0, roundness)
        let roundedPath: CGPath
        if cornerRadius > 0 {
            // The lab models roundness as a same-color, round-joined stroke.
            // Convert the canvas-pixel radius into the pre-scale path space,
            // then clip to the fill plus stroke so the gradient covers both.
            let strokeWidth = (cornerRadius * 2) / max(0.01, min(xScale, yScale))
            let union = CGMutablePath()
            union.addPath(kite)
            let stroke = kite.copy(
                strokingWithWidth: strokeWidth,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            union.addPath(stroke)
            roundedPath = union
        } else {
            roundedPath = kite
        }

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
        context.addPath(roundedPath)
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
            locations: [0.0, 0.59, 1.0]
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
/// and gradient, drawn on the same tile treatment as the cmux app icon: a
/// vertical plate gradient with a soft top rim highlight (#313131→#141414 in
/// Dark Aqua, #FFFFFF→#ECECEC in Aqua). The plate is rendered explicitly per
/// appearance so the icon always matches the effective cmux appearance (the
/// cmux setting when overridden, the system otherwise).
///
/// Keep the tile constants in sync with
/// `scripts/generate-computer-use-helper-icon.swift`, which bakes the same
/// artwork into `Resources/ComputerUseHelperIcon.icns` for System Settings.
@MainActor
enum ComputerUseHelperIconRenderer {
    private static let canvasSize = NSSize(width: 1_024, height: 1_024)
    private static let plateCornerRadius: CGFloat = 224
    // SolidJS logo-lab approved draft: translation 257.8472/257.8472,
    // scale 45.7900, width/height 1.0000, roundness 16.5, rotation 0;
    // transformed bounds 264.05/264.05/521.11/521.11; gradient midpoint 59%.
    private static let cursorTranslation = CGPoint(x: 257.8472, y: 257.8472)
    private static let cursorScale: CGFloat = 45.7900
    private static let cursorWidth: CGFloat = 1.0000
    private static let cursorHeight: CGFloat = 1.0000
    private static let cursorRoundness: CGFloat = 16.5
    private static let cursorRotation: CGFloat = 0
    private static let rimWidth: CGFloat = 14
    private static var cachedImages: [Bool: NSImage] = [:]

    private static func plateGradientColors(dark: Bool) -> [CGColor] {
        if dark {
            return [
                CGColor(gray: 0x31 / 255.0, alpha: 1.0),
                CGColor(gray: 0x14 / 255.0, alpha: 1.0),
            ]
        }
        return [
            CGColor(gray: 1.0, alpha: 1.0),
            CGColor(gray: 0xEC / 255.0, alpha: 1.0),
        ]
    }

    private static func rimGradientColors(dark: Bool) -> [CGColor] {
        if dark {
            return [
                CGColor(gray: 1.0, alpha: 0.34),
                CGColor(gray: 1.0, alpha: 0.05),
            ]
        }
        return [
            CGColor(gray: 0.0, alpha: 0.10),
            CGColor(gray: 0.0, alpha: 0.04),
        ]
    }

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
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Plate: the app icon's vertical tile gradient. This context is
        // flipped, so "top of the icon" is y = 0 here.
        context.saveGState()
        context.addPath(plate)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: plateGradientColors(dark: isDark) as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: canvas.midX, y: 0),
                end: CGPoint(x: canvas.midX, y: canvas.height),
                options: []
            )
        }
        context.restoreGState()

        // Rim: a soft highlight along the tile edge, brightest at the top,
        // matching the app icon's inner bevel.
        let rim = plate.copy(
            strokingWithWidth: rimWidth * 2,
            lineCap: .butt,
            lineJoin: .miter,
            miterLimit: 10
        )
        context.saveGState()
        context.addPath(plate)
        context.clip()
        context.addPath(rim)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: rimGradientColors(dark: isDark) as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: canvas.midX, y: 0),
                end: CGPoint(x: canvas.midX, y: canvas.height),
                options: []
            )
        }
        context.restoreGState()

        context.translateBy(x: cursorTranslation.x, y: cursorTranslation.y)
        ComputerUseCursorArtwork.draw(
            in: context,
            scale: cursorScale,
            width: cursorWidth,
            height: cursorHeight,
            roundness: cursorRoundness,
            rotation: cursorRotation
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

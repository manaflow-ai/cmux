import AppKit
import CmuxComputerUseVisuals

/// Produces the helper's rounded app icon with the live cursor's exact shape
/// and gradient, drawn on the same tile treatment as the cmux app icon: a
/// vertical plate gradient with a soft top rim highlight (#313131→#141414 in
/// Dark Aqua, #FFFFFF→#ECECEC in Aqua). The plate is rendered explicitly per
/// appearance so the icon always matches the effective cmux appearance (the
/// cmux setting when overridden, the system otherwise).
///
/// The geometry comes from `CmuxComputerUseVisuals`, which the generator also
/// imports before baking `Resources/ComputerUseHelperIcon.icns` for System
/// Settings.
@MainActor
enum ComputerUseHelperIconRenderer {
    private static let visualTokens = ComputerUseOnboardingVisualTokens.reference
    private static let canvasSize = NSSize(
        width: visualTokens.helperIconCanvasSize.width,
        height: visualTokens.helperIconCanvasSize.height
    )
    private static let plateCornerRadius = visualTokens.helperIconCornerRadius
    private static let cursorTranslation = visualTokens.helperIconCursorTranslation
    private static let cursorScale = visualTokens.helperIconCursorScale
    private static let rimWidth = visualTokens.helperIconRimWidth
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
        ComputerUseCursorArtwork().draw(
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
        ComputerUseCursorArtwork().draw(
            in: context,
            scale: Self.skyScale,
            outlineColor: NSColor.white.cgColor,
            outlineWidth: 1.7
        )
    }
}

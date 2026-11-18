public import AppKit

/// A glyph drawn with its ink, not its image, in the middle of the view, on whole pixels of the screen it is on (Lucas
/// 2026-11-18: "the containers/hover is not centered within the icon for majority if not all. we need consistency in
/// that, use flex or something else that is realiable"). A button cell centers a glyph's image, and Chrome's glyphs do
/// not sit in the middle of their own canvas, so their ink drew up to a pixel off the hover box's middle. This view reads
/// the glyph's lit pixels at the backing scale and copies them, unscaled, into an image the size of the view: as many
/// clear pixels above the ink as below, left as right. Where the counts cannot match (an odd and an even pixel count)
/// the odd pixel goes below and right, so the ink sits half a pixel up and left in every box alike. Clicks pass through
/// to the view behind it (its button).
public final class InkCenteredGlyphView: NSImageView {
    /// The glyph to center (a template image); nil draws nothing.
    public var glyph: NSImage? {
        didSet {
            guard glyph !== oldValue else { return }
            rendered = nil
            render()
        }
    }

    /// The size and scale the image was made for.
    private var rendered: (size: CGSize, scale: CGFloat)?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        isEditable = false
        unregisterDraggedTypes()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    // The image follows the view's size, its glyph and its screen's scale at once: no layout pass is needed.
    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rendered = nil
        render()
    }

    private func render() {
        guard let glyph, bounds.width > 0, bounds.height > 0 else {
            image = nil
            rendered = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let rendered, rendered.size == bounds.size, rendered.scale == scale, image != nil { return }
        rendered = (bounds.size, scale)
        image = Self.centered(glyph, in: bounds.size, scale: scale)
    }

    /// The alpha a pixel needs to count as ink: 2%, a row the eye reads as lit.
    static let inkAlpha: UInt8 = 5

    /// `glyph`'s ink centered in a canvas of `size` points at `scale` pixels a point: the glyph's pixels copied at a whole
    /// pixel offset, never resampled.
    public static func centered(_ glyph: NSImage, in size: CGSize, scale: CGFloat) -> NSImage? {
        let glyphWidth = Int((glyph.size.width * scale).rounded()), glyphHeight = Int((glyph.size.height * scale).rounded())
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard glyphWidth > 0, glyphHeight > 0, width > 0, height > 0,
              let source = context(width: glyphWidth, height: glyphHeight) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: source, flipped: false)
        glyph.draw(in: NSRect(x: 0, y: 0, width: glyphWidth, height: glyphHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = source.makeImage(), let data = source.data else { return nil }
        // The ink's bounds in pixels; a bitmap's first row in memory is its top row.
        let bytes = data.assumingMemoryBound(to: UInt8.self), stride = source.bytesPerRow
        var minX = glyphWidth, maxX = -1, minY = glyphHeight, maxY = -1
        for y in 0..<glyphHeight {
            for x in 0..<glyphWidth where bytes[y * stride + x * 4 + 3] > inkAlpha {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, let canvas = context(width: width, height: height) else { return nil }
        // Half the clear pixels on each side; the odd one goes right and below.
        let left = Int(floor(Double(width - (maxX - minX + 1)) / 2))
        let top = Int(floor(Double(height - (maxY - minY + 1)) / 2))
        // Drawing runs bottom-up: the glyph's top row lands `top - minY` rows under the canvas's top.
        canvas.draw(pixels, in: CGRect(x: left - minX, y: height - (top - minY) - glyphHeight, width: glyphWidth, height: glyphHeight))
        guard let centered = canvas.makeImage() else { return nil }
        let image = NSImage(cgImage: centered, size: size)
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityDescription
        return image
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

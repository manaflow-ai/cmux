import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// The UIKit names that the shared catalyst sources use, implemented on AppKit,
// Core Animation, Core Graphics and Core Text. Only what the shared files call
// is here. Each type keeps UIKit's behavior where it changes geometry or
// pixels (coordinates are y-down, as in UIKit; colors, fonts, paths and
// images draw the same bits); everything else is minimal.
//
// The shared files import UIKit on iOS and Mac Catalyst and AppKit here
// (`#if canImport(UIKit)`), and see these declarations instead.

typealias UIColor = NSColor
typealias UIFont = NSFont
typealias UIFontDescriptor = NSFontDescriptor

extension NSFontDescriptor.SymbolicTraits {
    static var traitBold: Self { .bold }
    static var traitItalic: Self { .italic }
}

extension NSFontDescriptor {
    /// UIKit's spelling returns an optional.
    @nonobjc func withSymbolicTraits(_ traits: SymbolicTraits) -> NSFontDescriptor? {
        let d: NSFontDescriptor = withSymbolicTraits(traits)
        return d
    }
}

// MARK: Fonts

// `UIFont` is NSFont. Catalyst in the Mac idiom ("Optimize for Mac") uses the
// macOS system font metrics, so `UIFont.systemFont` and AppKit's give the same
// advances (checked by the harness: text widths and caret positions agree).
// A command-line Catalyst binary without the app's Info.plist runs in the iPad
// idiom and tracks wider (+41 font units at 13 pt): measure inside the app.

// MARK: Geometry and small types

struct UIEdgeInsets: Equatable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    static let zero = UIEdgeInsets()
    init() {}
    init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) { self.top = top; self.left = left; self.bottom = bottom; self.right = right }
}

struct UIAccessibilityTraits: OptionSet {
    let rawValue: UInt64
    static let staticText = UIAccessibilityTraits(rawValue: 1 << 6)
    static let button = UIAccessibilityTraits(rawValue: 1 << 0)
}

enum UIScreen {
    /// The main screen's backing scale (the window's, once it is on a screen).
    static var main: Screen { Screen() }
    struct Screen { var scale: CGFloat { DisplayScale.current } }
}

/// The scale of the display the window is on (backingScaleFactor). The window
/// updates it in `viewDidChangeBackingProperties`; everything that rasterizes
/// reads it.
enum DisplayScale {
    /// The window view takes it as `Fixture.renderScale` through
    /// `setRenderScale(_:)` (rows, morph, compose and header bitmaps
    /// rasterize at it).
    static var current: CGFloat = 2
    /// The color space bitmaps are drawn in: the window's display space live
    /// (Core Animation then uploads them without a per-commit color
    /// conversion on the main thread, which cost 5-9 ms per fling frame),
    /// sRGB in captures and the harness (as Catalyst's renderer).
    static var colorSpace: CGColorSpace = LabColorSpace.sRGB // cmux: no force unwrap
}

// MARK: Drawing context (UIGraphics)

/// UIKit's current context. Drawing code calls `UIGraphicsGetCurrentContext()`
/// and `UIColor.setFill()`; both must see the same y-down context, so a scope
/// sets AppKit's current graphics context (per thread: rows render on
/// background queues).
func UIGraphicsGetCurrentContext() -> CGContext? { NSGraphicsContext.current?.cgContext }

func UIRectFill(_ rect: CGRect) { UIGraphicsGetCurrentContext()?.fill(rect) }

enum ContextScope {
    static func run(_ ctx: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }
}

final class UIGraphicsImageRendererFormat {
    enum Range { case automatic, standard, extended, unspecified }
    var scale: CGFloat = 2
    var opaque = false
    var preferredRange: Range = .automatic
    init() { scale = DisplayScale.current }
}

final class UIGraphicsImageRendererContext {
    let cgContext: CGContext
    init(_ c: CGContext) { cgContext = c }
    func fill(_ r: CGRect) { cgContext.fill(r) }
}

/// Renders into an 8-bit sRGB bitmap (premultiplied BGRA, as UIKit's standard
/// range) with a y-down coordinate system at `format.scale`.
final class UIGraphicsImageRenderer {
    let size: CGSize
    let format: UIGraphicsImageRendererFormat
    init(size: CGSize, format: UIGraphicsImageRendererFormat) { self.size = size; self.format = format }
    convenience init(size: CGSize) { self.init(size: size, format: UIGraphicsImageRendererFormat()) }

    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let s = format.scale
        let pw = max(1, Int((size.width * s).rounded(.up))), ph = max(1, Int((size.height * s).rounded(.up)))
        let info = CGBitmapInfo.byteOrder32Little.rawValue | (format.opaque ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DisplayScale.colorSpace, bitmapInfo: info) else { return UIImage() }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: s, y: -s)
        ContextScope.run(ctx) { actions(UIGraphicsImageRendererContext(ctx)) }
        return UIImage(cgImage: ctx.makeImage(), scale: s)
    }
}

// MARK: Images

final class UIImage {
    enum Orientation { case up }
    enum RenderingMode { case automatic, alwaysOriginal, alwaysTemplate }
    enum SymbolWeight { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
        var ns: NSFont.Weight {
            switch self {
            case .ultraLight: return .ultraLight
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            }
        }
    }
    struct SymbolConfiguration { var pointSize: CGFloat; var weight: SymbolWeight }

    let cgImage: CGImage?
    let scale: CGFloat
    /// Symbol images keep their vector source and draw it at the target size.
    private let symbol: (name: String, config: SymbolConfiguration, tint: NSColor?)?
    private let symbolSize: CGSize

    init() { cgImage = nil; scale = 1; symbol = nil; symbolSize = .zero }
    init(cgImage: CGImage?, scale: CGFloat = 1, orientation: Orientation = .up) {
        self.cgImage = cgImage; self.scale = scale; symbol = nil; symbolSize = .zero
    }
    convenience init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(cgImage: img, scale: 1)
    }
    convenience init?(contentsOfFile path: String) {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        self.init(data: d)
    }
    private init(symbol: (String, SymbolConfiguration, NSColor?), size: CGSize) {
        cgImage = nil; scale = DisplayScale.current; self.symbol = symbol; symbolSize = size
    }
    convenience init?(systemName name: String, withConfiguration config: SymbolConfiguration? = nil) {
        let c = config ?? SymbolConfiguration(pointSize: 17, weight: .regular)
        guard let img = UIImage.nsSymbol(name, c, nil) else { return nil }
        self.init(symbol: (name, c, nil), size: UIImage.uikitSymbolSize(name, c, img))
    }

    /// UIKit sizes a symbol image to the device pixel (0.5 pt); AppKit rounds
    /// its image box up to whole points, adding the excess at the right and
    /// the top. The width is the alignment rect's; heights that differ are
    /// measured on Catalyst (the harness writes them to meta.json).
    static let measuredHeights: [String: CGFloat] = ["plus 15.0": 15.5, "video 18.0": 17.5]
    static func uikitSymbolSize(_ name: String, _ c: SymbolConfiguration, _ img: NSImage) -> CGSize {
        let key = "\(name) \(String(format: "%.1f", Double(c.pointSize)))"
        return CGSize(width: img.alignmentRect.width, height: measuredHeights[key] ?? img.size.height)
    }

    private static func nsSymbol(_ name: String, _ c: SymbolConfiguration, _ tint: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var cfg = NSImage.SymbolConfiguration(pointSize: c.pointSize, weight: c.weight.ns)
        if let tint { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [tint])) }
        return base.withSymbolConfiguration(cfg)
    }

    var size: CGSize {
        if symbol != nil { return symbolSize }
        guard let cg = cgImage else { return .zero }
        return CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
    }

    func withTintColor(_ color: NSColor, renderingMode: RenderingMode = .automatic) -> UIImage {
        guard let s = symbol else { return self }
        return UIImage(symbol: (s.name, s.config, color), size: symbolSize)
    }

    /// Decoded into an sRGB bitmap now (UIKit decodes for display).
    func preparingForDisplay() -> UIImage? {
        guard let cg = cgImage else { return self }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: LabColorSpace.sRGB, // cmux: no force unwrap
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return self }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return UIImage(cgImage: ctx.makeImage(), scale: scale)
    }

    /// Draw upright into the current (y-down) context.
    func draw(in rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let s = symbol {
            guard let img = UIImage.nsSymbol(s.name, s.config, s.tint) else { return }
            ctx.saveGState()
            // AppKit's box at its natural size, bottom-left on UIKit's box
            // (the excess lies at the right and the top): the glyph lands
            // where UIKit draws it.
            let sx = rect.width / max(0.01, symbolSize.width), sy = rect.height / max(0.01, symbolSize.height)
            let natural = CGSize(width: img.size.width * sx, height: img.size.height * sy)
            let box = CGRect(x: rect.minX, y: rect.maxY - natural.height, width: natural.width, height: natural.height)
            ContextScope.run(ctx) {
                img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            ctx.restoreGState()
            return
        }
        guard let cg = cgImage else { return }
        if ResolutionAudit.recording {
            // An image drawn above its source pixel size (resolution audit).
            let device = abs(ctx.ctm.a)
            if CGFloat(cg.width) + 1 < rect.width * device || CGFloat(cg.height) + 1 < rect.height * abs(ctx.ctm.d) {
                ResolutionAudit.drawFindings.append(["kind": "imageDrawnAboveSourceSize", "pixels": [cg.width, cg.height],
                                                     "drawnPixels": [Double(rect.width * device), Double(rect.height * abs(ctx.ctm.d))]])
            }
        }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: Paths

/// UIKit's path object over a CGMutablePath, with UIKit's constructors
/// (continuous rounded rectangles, ovals) and current-context drawing.
final class UIBezierPath {
    private(set) var path: CGMutablePath
    var lineWidth: CGFloat = 1
    var lineCapStyle: CGLineCap = .butt
    var lineJoinStyle: CGLineJoin = .miter
    var miterLimit: CGFloat = 10
    var usesEvenOddFillRule = false

    init() { path = CGMutablePath() }
    init(cgPath: CGPath) { path = cgPath.mutableCopy() ?? CGMutablePath() }
    init(rect: CGRect) { path = CGMutablePath(); path.addRect(rect) }
    init(ovalIn rect: CGRect) { path = UIKitRoundedRect.oval(rect) }
    init(roundedRect rect: CGRect, cornerRadius: CGFloat) { path = UIKitRoundedRect.path(rect, radius: cornerRadius) }

    var cgPath: CGPath {
        get { path }
        set { path = newValue.mutableCopy() ?? CGMutablePath() }
    }
    var bounds: CGRect { path.boundingBoxOfPath }
    var isEmpty: Bool { path.isEmpty }

    func move(to p: CGPoint) { path.move(to: p) }
    func addLine(to p: CGPoint) { path.addLine(to: p) }
    func addCurve(to p: CGPoint, controlPoint1 c1: CGPoint, controlPoint2 c2: CGPoint) { path.addCurve(to: p, control1: c1, control2: c2) }
    func addQuadCurve(to p: CGPoint, controlPoint c: CGPoint) { path.addQuadCurve(to: p, control: c) }
    /// UIKit's `clockwise` is in its y-down space: Core Graphics' flag is the opposite.
    func addArc(withCenter c: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        path.addArc(center: c, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: !clockwise)
    }
    func close() { path.closeSubpath() }
    func apply(_ t: CGAffineTransform) {
        var t = t
        if let p = path.mutableCopy(using: &t) { path = p }
    }
    func append(_ other: UIBezierPath) { path.addPath(other.path) }

    func fill() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.fillPath(using: usesEvenOddFillRule ? .evenOdd : .winding)
        ctx.restoreGState()
    }
    func stroke() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(lineCapStyle)
        ctx.setLineJoin(lineJoinStyle)
        ctx.setMiterLimit(miterLimit)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
    func addClip() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.addPath(path)
        ctx.clip(using: usesEvenOddFillRule ? .evenOdd : .winding)
    }
}

// MARK: Pasteboard

enum UIPasteboard {
    static var general: NSPasteboard { .general }
}

extension NSPasteboard {
    var string: String? {
        get { string(forType: .string) }
        set { clearContents(); if let newValue { setString(newValue, forType: .string) } }
    }
}

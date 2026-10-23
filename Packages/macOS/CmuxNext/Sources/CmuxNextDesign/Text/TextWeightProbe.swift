#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextWakeups

/// `debug.text_weight` (DEBUG; text-weight-e2e.py, cx-8w027.12): the glyph coverage of
/// ``ChromeLabel`` and ``ChromeTextLayer`` next to a stock `NSTextField` with the same text, font
/// and color, as the window server shows them.
///
/// A borderless window in a dark (Catppuccin Mocha) or light (Latte) theme shows one row per
/// (ink, font) and one column per class, so the three draw at the same height. Each row's coverage is the sum over its pixels of how far each pixel moved
/// from the background toward the ink (luminance); a class's value is its coverage over the stock
/// row's, so 1 is the stock weight.
public struct TextWeightProbe {
    public let dark: Bool

    public init(dark: Bool) { self.dark = dark }

    private static let text = "Workspace notes 0123 quick brown fox"
    private static let fonts: [(String, NSFont)] = [
        ("13r", .systemFont(ofSize: TypeScale.body)), ("12m", .systemFont(ofSize: TypeScale.detail, weight: .medium)),
        ("11r", .systemFont(ofSize: TypeScale.caption)),
    ]
    private static let rowHeight: CGFloat = 22
    /// Space around the grid: a window's edge draws a hairline that is no row's ink.
    private static let margin: CGFloat = 16

    /// `<ink>.<font>.label` and `<ink>.<font>.layer`: coverage over stock; `scale`: the backing scale.
    public func measure() async -> [String: Double] {
        let background = Self.color(dark ? 0x1E1E2E : 0xEFF1F5)
        let inks: [(String, NSColor)] = dark
            ? [("text", Self.color(0xCDD6F4)), ("subtext", Self.color(0xA6ADC8)), ("overlay", Self.color(0x6C7086)), ("label", .labelColor)]
            : [("text", Self.color(0x4C4F69)), ("subtext", Self.color(0x6C6F85)), ("overlay", Self.color(0x9CA0B0)), ("label", .labelColor)]
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var rows: [(key: String, ink: NSColor)] = []
        for (inkName, ink) in inks {
            for (fontName, _) in Self.fonts {
                for kind in ["stock", "label", "layer"] { rows.append(("\(inkName).\(fontName).\(kind)", ink)) }
            }
        }
        let width: CGFloat = 340, lines = rows.count / 3
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width * 3 + Self.margin * 2,
                                                  height: Self.rowHeight * CGFloat(lines) + Self.margin * 2),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = background
        let root = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = background.cgColor
        window.contentView = root
        let scale = window.backingScaleFactor
        for (index, row) in rows.enumerated() {
            let font = Self.fonts[(index / 3) % Self.fonts.count].1
            let frame = NSRect(x: Self.margin + width * CGFloat(index % 3) + 12,
                               y: root.bounds.height - Self.margin - Self.rowHeight * CGFloat(index / 3 + 1) + 2,
                               width: width - 24, height: 18)
            switch index % 3 {
            case 0:
                let field = NSTextField(labelWithString: Self.text)
                field.font = font
                field.textColor = row.ink
                field.frame = frame
                root.addSubview(field)
            case 1:
                let label = ChromeLabel(labelWithString: Self.text)
                label.font = font
                label.textColor = row.ink
                label.frame = frame
                root.addSubview(label)
            default:
                let host = NSView(frame: frame)
                host.wantsLayer = true
                root.addSubview(host)
                let layer = ChromeTextLayer()
                layer.string = Self.text
                layer.font = font
                layer.contentsScale = scale
                var ink: CGColor?
                appearance.performAsCurrentDrawingAppearance { ink = row.ink.cgColor }
                layer.foregroundColor = ink
                layer.frame = host.bounds
                host.layer?.addSublayer(layer)
            }
        }
        window.orderFrontRegardless()
        // close, not only orderOut: willClose invalidates the window's FrameScheduler (its link and observer).
        defer { window.close() }
        // The window server shows the rows some frames after the commit (later on a loaded host):
        // read them once two captures a few frames apart agree.
        var shown: CGImage?
        for _ in 0..<20 {
            await Self.frames(3, of: window)
            let next = window.compositedSnapshot() // perf-gate-ok: debug.text_weight probe window
            if let next, let previous = shown, Self.same(previous, next) { break }
            shown = next
        }
        guard let image = shown else { return [:] }
        var ground: (Double, Double, Double) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance { ground = Self.rgb(background) }
        var result: [String: Double] = ["scale": Double(scale)]
        var stock = 0.0
        for (index, row) in rows.enumerated() {
            var ink: (Double, Double, Double, Double) = (0, 0, 0, 1)
            appearance.performAsCurrentDrawingAppearance {
                let parts = Self.rgb(row.ink)
                ink = (parts.0, parts.1, parts.2, Double(row.ink.usingColorSpace(.sRGB)?.alphaComponent ?? 1))
            }
            let coverage = Self.coverage(image, cell: (index / 3, index % 3), width: width, scale: CGFloat(image.height) / window.frame.height,
                                         ground: ground, ink: ink)
            if index % 3 == 0 { stock = coverage } else { result[row.key] = stock == 0 ? 0 : coverage / stock }
        }
        return result
    }

    private static func same(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return CFEqual(da, db)
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgb(_ color: NSColor) -> (Double, Double, Double) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// How far the cell's pixels (`cell`: row, column) moved from `ground` toward `ink` over `ground`, summed.
    private static func coverage(_ image: CGImage, cell: (row: Int, column: Int), width cellWidth: CGFloat, scale: CGFloat, ground: (Double, Double, Double),
                                 ink: (Double, Double, Double, Double)) -> Double {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let background = luminance(ground.0, ground.1, ground.2) * 255
        let shown = luminance(ground.0 + (ink.0 - ground.0) * ink.3, ground.1 + (ink.1 - ground.1) * ink.3,
                              ground.2 + (ink.2 - ground.2) * ink.3) * 255
        guard abs(shown - background) > 1 else { return 0 }
        // Row 0 of the bitmap is the top of the window.
        let top = Int(((margin + CGFloat(cell.row) * rowHeight) * scale).rounded())
        let bottom = min(height, Int(((margin + CGFloat(cell.row + 1) * rowHeight) * scale).rounded()))
        let left = Int(((margin + CGFloat(cell.column) * cellWidth) * scale).rounded())
        let right = min(width, Int(((margin + CGFloat(cell.column + 1) * cellWidth) * scale).rounded()))
        var sum = 0.0
        for y in top..<bottom {
            for x in left..<right {
                let pixel = (y * width + x) * 4
                sum += (luminance(Double(bytes[pixel]), Double(bytes[pixel + 1]), Double(bytes[pixel + 2])) - background) / (shown - background)
            }
        }
        return sum
    }
}

extension TextWeightProbe {
    /// Resumes after `count` frames of `window`'s FrameScheduler (a stalled link still ticks).
    fileprivate static func frames(_ count: Int, of window: NSWindow) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var remaining = count
            // The scheduler holds the active client; it drops it after the last frame.
            let client = FrameClient(owner: "debug.text_weight", isAnimation: false, on: FrameScheduler.forWindow(window)) { _ in
                remaining -= 1
                guard remaining <= 0 else { return true }
                continuation.resume()
                return false
            }
            client.activate()
        }
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// One column's backdrop in the Liquid Glass Parity playground (``GlassParityPlayground``). Every column
/// draws the same picture in its own coordinates, so the pixels under a surface are the same in each
/// column. Deterministic: no time, no randomness, nothing of the person's.
///
/// - `plain`: the theme's window background.
/// - `wallpaper`: a bright gradient with stripes and discs, detail a blur and a lensing rim both show.
/// - `terminal`: an opaque terminal of colored text.
/// - `terminal-translucent`: the same terminal at 0.6 background opacity over the wallpaper, as cmux
///   draws a see-through terminal over a custom background.
/// - `image`: the Mac's own desktop picture when one is installed, else the wallpaper.
final class GlassParityBackdropView: NSView {
    /// A fixed test color (0xRRGGBB): the backdrop is test data, the same in every theme.
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha) // colour-allow: the playground's fixed test backdrop, data not UI
    }

    var backdrop: GlassParityPlayground.Backdrop = .wallpaper
    /// The Mac's desktop picture for `image` (``GlassParityPlayground`` reads it off the main actor).
    var picture: NSImage?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        switch backdrop {
        case .plain:
            Palette.windowBackground.setFill()
            bounds.fill()
        case .wallpaper:
            Self.drawWallpaper(in: bounds)
        case .terminal:
            drawTerminal(opacity: 1)
        case .terminalTranslucent:
            Self.drawWallpaper(in: bounds)
            drawTerminal(opacity: 0.6)
        case .image:
            if let image = picture {
                Self.drawAspectFill(image, in: bounds)
            } else {
                Self.drawWallpaper(in: bounds)
            }
        }
    }

    static func drawWallpaper(in bounds: CGRect) {
        let gradient = NSGradient(colors: [
            Self.rgb(0xFA6B36),
            Self.rgb(0xED2E8C),
            Self.rgb(0x4559F2),
            Self.rgb(0x1AC7B2),
        ])
        gradient?.draw(in: bounds, angle: -60)
        // Diagonal stripes: a rim's lensing bends them, a blur softens them.
        Self.rgb(0xFFFFFF, alpha: 0.28).setFill()
        let step: CGFloat = 18
        var x = -bounds.height
        while x < bounds.width {
            let stripe = NSBezierPath()
            stripe.move(to: CGPoint(x: x, y: 0))
            stripe.line(to: CGPoint(x: x + 7, y: 0))
            stripe.line(to: CGPoint(x: x + 7 + bounds.height, y: bounds.height))
            stripe.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
            stripe.close()
            stripe.fill()
            x += step
        }
        // Discs of strong color across every row's surface edge.
        let discs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (40, 30, 34, Self.rgb(0xFFD91A)),
            (250, 90, 40, Self.rgb(0x0D0D1A)),
            (120, 160, 30, Self.rgb(0xFFFFFF)),
            (210, 250, 44, Self.rgb(0x1AE64C)),
            (60, 330, 36, Self.rgb(0x0D0D1A)),
            (260, 400, 34, Self.rgb(0xFFD91A)),
        ]
        for (cx, cy, radius, color) in discs {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawTerminal(opacity: CGFloat) {
        let background = isDark ? Self.rgb(0x17171C, alpha: opacity)
            : Self.rgb(0xFFFFFF, alpha: opacity)
        background.setFill()
        bounds.fill(using: .sourceOver)
        let font = NSFont.monospacedSystemFont(ofSize: TypeScale.detail, weight: .regular)
        let palette: [NSColor] = isDark
            ? [Self.rgb(0xD9D9D9), Self.rgb(0x8CD973),
               Self.rgb(0x73B2FF), Self.rgb(0xFF8C80)]
            : [Self.rgb(0x262626), Self.rgb(0x1A801A),
               Self.rgb(0x1A4CCC), Self.rgb(0xBF261A)]
        let words = ["$", "cargo", "build", "--release", "Compiling", "cmux-tui", "v0.1.0", "warning:", "unused", "ok", "142",
                     "tests", "passed;", "0", "failed", "finished", "in", "3.21s", "git", "status", "modified:", "glass.css"]
        var index = 0
        var y: CGFloat = 4
        while y < bounds.height {
            var x: CGFloat = 6
            while x < bounds.width - 20 {
                let word = words[index % words.count]
                let color = palette[(index / 3) % palette.count]
                let text = NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: color])
                text.draw(at: CGPoint(x: x, y: y))
                x += text.size().width + 7
                index += 1
            }
            y += 15
        }
    }

    static func drawAspectFill(_ image: NSImage, in bounds: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The backdrop under every renderer of the Liquid Glass Parity playground (``GlassParityPlayground``).
/// Deterministic: no time, no randomness, nothing of the person's.
///
/// - `plain`: the theme's window background.
/// - `color`: a custom background color (`color`).
/// - `wallpaper`: a bright gradient with stripes and discs, detail a blur and a lensing rim both show.
/// - `terminal`: a terminal of colored text at background opacity `terminalOpacity` over the wallpaper,
///   as cmux draws a see-through terminal over a custom background (1: opaque).
/// - `image`: the Mac's own desktop picture when one is installed, else the wallpaper.
///
/// `offset` moves the picture under the glass (down and right), as a backdrop that scrolls or drags.
/// ``animate(for:done:)`` moves it every frame (a layer transform, so only the window server redraws the
/// glass over it): the frame-time measure of the glass over a moving backdrop.
///
/// The view is ``margin`` larger than the stage on every side (its bounds keep the stage's coordinates), so
/// the moving picture always covers the stage.
final class GlassParityBackdropView: NSView {
    static let margin: CGFloat = 64

    /// A fixed test color (0xRRGGBB): the backdrop is test data, the same in every theme.
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha) // colour-allow: the playground's fixed test backdrop, data not UI
    }

    var backdrop: GlassParityPlayground.Backdrop = .wallpaper
    /// The Mac's desktop picture for `image` (``GlassParityPlayground`` reads it off the main actor).
    var picture: NSImage?
    var color: UInt32 = 0x2D6CDF
    var terminalOpacity: CGFloat = 1
    var offset: CGFloat = 0
    private var frames: FrameClient?
    private var animationStart: CFTimeInterval = 0
    private var animationEnd: CFTimeInterval = 0
    private var animationDone: (() -> Void)?

    /// A backdrop over `stage` (the stage's coordinates), ``margin`` larger on every side.
    init(stage: NSRect) {
        let margin = Self.margin
        super.init(frame: stage.insetBy(dx: -margin, dy: -margin))
        bounds.origin = CGPoint(x: stage.minX - margin, y: stage.minY - margin)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The stripes run past the column's edge; unclipped (the default since macOS 14) they painted
        // over the next column's glass.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Moves the picture under the glass every display frame for `seconds` (a circle of ``margin`` / 2 points,
    /// once a second), then puts it back and calls `done`.
    func animate(for seconds: Double, done: @escaping () -> Void) {
        stopAnimation()
        animationStart = CACurrentMediaTime()
        animationEnd = animationStart + seconds
        animationDone = done
        // The window's frames (its FrameScheduler): one step a display frame until the end.
        let frames = FrameClient(owner: "glass-parity.backdrop", view: self) { [weak self] tick in
            self?.step(tick.targetTimestamp) ?? false
        }
        self.frames = frames
        frames.activate()
    }

    /// Moves the picture for the frame shown at `now`; false once the animation ended.
    private func step(_ now: CFTimeInterval) -> Bool {
        let phase = (now - animationStart) * 2 * .pi
        let radius = Self.margin / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(now >= animationEnd ? .identity
            : CGAffineTransform(translationX: radius * CGFloat(sin(phase)), y: radius * CGFloat(1 - cos(phase))))
        CATransaction.commit()
        guard now >= animationEnd else { return true }
        stopAnimation()
        return false
    }

    private func stopAnimation() {
        frames?.deactivate()
        frames = nil
        let done = animationDone
        animationDone = nil
        done?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        // The picture moved by `offset`, drawn over a box that still covers the view.
        NSGraphicsContext.current?.cgContext.translateBy(x: offset, y: offset)
        let area = bounds.offsetBy(dx: -offset, dy: -offset)
        switch backdrop {
        case .plain:
            Palette.windowBackground.setFill()
            area.fill()
        case .color:
            Self.rgb(color).setFill()
            area.fill()
        case .wallpaper:
            Self.drawWallpaper(in: area)
        case .terminal:
            Self.drawWallpaper(in: area)
            drawTerminal(opacity: terminalOpacity, in: area)
        case .image:
            if let image = picture {
                Self.drawAspectFill(image, in: area)
            } else {
                Self.drawWallpaper(in: area)
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
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            let stripe = NSBezierPath()
            stripe.move(to: CGPoint(x: x, y: bounds.minY))
            stripe.line(to: CGPoint(x: x + 7, y: bounds.minY))
            stripe.line(to: CGPoint(x: x + 7 + bounds.height, y: bounds.maxY))
            stripe.line(to: CGPoint(x: x + bounds.height, y: bounds.maxY))
            stripe.close()
            stripe.fill()
            x += step
        }
        // Discs of strong color across every surface's edge (the stage's grid, GlassParityPlayground).
        let discs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (40, 30, 34, Self.rgb(0xFFD91A)),
            (250, 90, 40, Self.rgb(0x0D0D1A)),
            (380, 34, 30, Self.rgb(0xFFFFFF)),
            (566, 96, 36, Self.rgb(0x1AE64C)),
            (120, 150, 30, Self.rgb(0xFFFFFF)),
            (300, 200, 44, Self.rgb(0x1AE64C)),
            (520, 150, 34, Self.rgb(0x0D0D1A)),
            (60, 300, 36, Self.rgb(0x0D0D1A)),
            (262, 326, 34, Self.rgb(0xFFD91A)),
            (450, 270, 40, Self.rgb(0xFFD91A)),
        ]
        for (cx, cy, radius, color) in discs {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.minX + cx - radius, y: bounds.minY + cy - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawTerminal(opacity: CGFloat, in bounds: CGRect) {
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
        var y = bounds.minY + 4
        while y < bounds.maxY {
            var x = bounds.minX + 6
            while x < bounds.maxX - 20 {
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

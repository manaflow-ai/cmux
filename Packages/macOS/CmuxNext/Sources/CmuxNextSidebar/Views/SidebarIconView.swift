import AppKit
import CmuxNextIcons
import CmuxNextDesign
import QuartzCore

/// Workspace icon: the user's choice, an SF Symbol (tinted with the
/// workspace color), one emoji (on a chip of the workspace color) or a color
/// alone shown as a small dot; a browser workspace's page icon, untinted;
/// else nothing. It has no kind glyph or agent brand fallback: workspace rows
/// are text only by default (WORKSPACE-ROWS-NO-DEFAULT-ICON, Lawrence 2026-10-14).
final class SidebarIconView: NSView {
    private let imageView = DecorativeImageView()
    private let swatch = CALayer()
    private let emoji = SidebarEmojiGlyphView()
    private var icon: WorkspaceIcon?
    /// What the last `configure` drew from (the glyphs scale with the title font).
    private var configured: (icon: WorkspaceIcon?, pointSize: CGFloat)?
    /// One ink for every symbol, tinted or not (the solid group header's
    /// glyph ink, cx-qno.22: a red icon must not vanish on a red bar); nil
    /// keeps a symbol's tint and draws an uncolored one in the secondary text color.
    var symbolInk: NSColor? { didSet { if symbolInk != oldValue { needsDisplay = true } } }

    /// Start the glyph's ink (an emoji, a symbol, a favicon, a dot, or an emoji's chip) at the view's leading edge
    /// instead of centering it: a workspace row's icon column, whose box starts at the row inset (Lawrence msg 19643,
    /// `SidebarStyle.iconColumnGlyphX`). Group and section headers keep the glyph centered.
    var leadsWithInk = false {
        didSet {
            guard leadsWithInk != oldValue else { return }
            needsLayout = true
        }
    }
    /// The cache key of the shown image's ink (`SidebarGlyphInk`): the symbol and size, or the favicon image.
    private var inkKey = ""

    /// Rows reserve room only for a chosen icon or a page's favicon.
    static func showsIcon(_ icon: WorkspaceIcon?) -> Bool { icon != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        addSubview(emoji)
        // Decorative: the row it sits in names the workspace, group or machine.
        setAccessibilityElement(false)
        emoji.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var wantsUpdateLayer: Bool { true }

    /// The chip behind a colored emoji: the color, light enough that the emoji reads.
    static let chipAlpha: CGFloat = 0.35

    /// Whether the emoji sits on a color chip (tests).
    var showsChip: Bool {
        if case .emoji(_, _?)? = icon { !swatch.isHidden } else { false }
    }

    func configure(icon: WorkspaceIcon?) {
        // A row's status tick configures the row again with the same icon: keep the image. A new
        // NSImage redraws (pack icons run their drawing handler) and relays out at the next display.
        let pointSize = SidebarStyle.titleFont.pointSize
        if let configured, configured.icon == icon, configured.pointSize == pointSize { return }
        configured = (icon, pointSize)
        self.icon = icon
        isHidden = !Self.showsIcon(icon)
        emoji.isHidden = true
        switch icon {
        case let .emoji(text, chip)?:
            emoji.text = text
            emoji.fill = chip == nil ? 0.86 : 0.7
            emoji.isHidden = false
            imageView.isHidden = true
        case let .symbol(name, tint)?:
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage.icon(.terminal, size: SidebarStyle.kindGlyphSize)
            inkKey = "symbol|\(name)|\(pointSize)"
            imageView.isHidden = false
        case let .favicon(favicon)?:
            imageView.image = NSImage(cgImage: favicon.image, size: NSSize(width: SidebarStyle.kindGlyphSize, height: SidebarStyle.kindGlyphSize))
            inkKey = "favicon|\(UInt(bitPattern: ObjectIdentifier(favicon.image).hashValue))"
            imageView.isHidden = false
        case .swatch?, nil:
            imageView.image = nil
            imageView.isHidden = true
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            let tint: NSColor? = if case let .symbol(_, tint)? = icon {
                symbolInk ?? tint.map(SidebarStyle.color) ?? Palette.textSecondary
            } else if icon == nil {
                Palette.textSecondary
            } else {
                nil
            }
            if let tint { imageView.setTint(tint) }
            switch icon {
            case let .swatch(color)?:
                swatch.isHidden = false
                swatch.backgroundColor = SidebarStyle.color(color).cgColor
            case let .emoji(_, chip?)?:
                swatch.isHidden = false
                swatch.backgroundColor = SidebarStyle.color(chip).withAlphaComponent(Self.chipAlpha).cgColor
            default:
                swatch.isHidden = true
            }
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // A row's icon column can be wider than the glyph (the comfortable 20 pt box): the glyph keeps its own
        // `iconBox` square, centered in the column, so density moves the column and not the glyph's size.
        // `leadsWithInk`: each glyph's drawn ink starts at x 0 by `SidebarStyle.iconColumnGlyphX`; the chip, the dot and
        // the emoji's square are their own ink, a symbol or favicon image is measured (`SidebarGlyphInk`).
        let side = min(bounds.width, bounds.height, SidebarStyle.iconBox)
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let content = CGRect(x: leadsWithInk ? SidebarStyle.iconColumnGlyphX(leading: 0, ink: square) : (bounds.width - side) / 2,
                             y: (bounds.height - side) / 2, width: side, height: side)
        imageView.frame = leadsWithInk ? leadingImageFrame(side: side) ?? content : content
        emoji.frame = content
        // A bare emoji's ink is narrower than its square: it starts its ink at the edge; on a chip it centers in it.
        if case .emoji(_, nil)? = icon { emoji.leadsWithInk = leadsWithInk } else { emoji.leadsWithInk = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .emoji(_, _?)? = icon {
            // The chip fills the icon square behind the emoji.
            swatch.frame = content
            swatch.cornerRadius = bounds.height * 0.25
        } else {
            let dot = SidebarStyle.dotSize
            let x = leadsWithInk ? SidebarStyle.iconColumnGlyphX(leading: 0, ink: CGRect(x: 0, y: 0, width: dot, height: dot))
                : (bounds.width - dot) / 2
            swatch.frame = CGRect(x: x, y: (bounds.height - dot) / 2, width: dot, height: dot)
            swatch.cornerRadius = dot / 2
        }
        CATransaction.commit()
        needsDisplay = true
    }

    /// The image view's frame that draws the shown symbol or favicon whole (scaled down into a `side` square, never
    /// up) with its measured ink starting at x 0, centered vertically, on the pixel grid. Nil without a measurable image.
    private func leadingImageFrame(side: CGFloat) -> CGRect? {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              let ink = SidebarGlyphInk.shared.box(of: image, glyph: inkKey) else { return nil }
        let fit = min(1, side / image.size.width, side / image.size.height)
        let width = image.size.width * fit, height = image.size.height * fit
        let drawnInk = CGRect(x: ink.minX * fit, y: ink.minY * fit, width: ink.width * fit, height: ink.height * fit)
        let scale = window?.backingScaleFactor ?? 2
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        return CGRect(x: snap(SidebarStyle.iconColumnGlyphX(leading: 0, ink: drawnInk)), y: snap((bounds.height - height) / 2),
                      width: width, height: height)
    }
}

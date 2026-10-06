import AppKit
import CmuxAgentBrands
import CmuxNextIcons
import CmuxNextDesign
import QuartzCore

/// Workspace icon: the user's choice, an SF Symbol (tinted with the
/// workspace color), one emoji (on a chip of the workspace color) or a color
/// alone shown as a small dot; else the row's type glyph from the icon
/// registry, or the brand mark of the agent it shows, at row size.
final class SidebarIconView: NSView {
    private let imageView = NSImageView()
    private let swatch = CALayer()
    private let emoji = NSTextField(labelWithString: "")
    private var icon: WorkspaceIcon?

    /// Rows reserve room for a chosen icon or a built-in type glyph.
    static func showsIcon(_ icon: WorkspaceIcon?, fallback: IconName? = nil) -> Bool {
        icon != nil || fallback != nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        emoji.alignment = .center
        addSubview(emoji)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// The chip behind a colored emoji: the color, light enough that the emoji reads.
    static let chipAlpha: CGFloat = 0.35

    /// The emoji drawn now, or nil (tests).
    var emojiText: String? { emoji.isHidden ? nil : emoji.stringValue }

    /// Whether the emoji sits on a color chip (tests).
    var showsChip: Bool {
        if case .emoji(_, _?)? = icon { !swatch.isHidden } else { false }
    }

    func configure(icon: WorkspaceIcon?, fallback: IconName? = nil, brand: String? = nil) {
        self.icon = icon
        isHidden = !Self.showsIcon(icon, fallback: fallback)
        emoji.isHidden = true
        switch icon {
        case let .emoji(text, _)?:
            emoji.stringValue = text
            emoji.isHidden = false
            imageView.isHidden = true
        case let .symbol(name, tint)?:
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.isHidden = false
        case .swatch?:
            imageView.isHidden = true
        case nil:
            let side = SidebarStyle.kindGlyphSize
            imageView.image = brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
                ?? fallback.map { NSImage.icon($0, size: side, style: .line) }
            imageView.isHidden = imageView.image == nil
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            let tint: NSColor? = if case let .symbol(_, tint)? = icon {
                tint.map(SidebarStyle.color) ?? Palette.textSecondary
            } else if icon == nil {
                Palette.textSecondary
            } else {
                nil
            }
            if let tint { imageView.contentTintColor = tint }
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
        imageView.frame = bounds
        emoji.font = .systemFont(ofSize: max(8, bounds.height * 0.72))
        let height = ceil(emoji.intrinsicContentSize.height)
        emoji.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case .emoji(_, _?)? = icon {
            // The chip fills the icon square behind the emoji.
            swatch.frame = bounds
            swatch.cornerRadius = bounds.height * 0.25
        } else {
            let side = SidebarStyle.dotSize
            swatch.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            swatch.cornerRadius = side / 2
        }
        CATransaction.commit()
        needsDisplay = true
    }
}

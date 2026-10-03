import AppKit
import CmuxNextIcons
import CmuxNextDesign
import QuartzCore

/// Workspace icon, shown only when the user chose one: an SF Symbol, one
/// emoji, or a color shown as a small dot.
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

    /// The emoji drawn now, or nil (tests).
    var emojiText: String? { emoji.isHidden ? nil : emoji.stringValue }

    func configure(icon: WorkspaceIcon?, fallback: IconName? = nil) {
        self.icon = icon
        isHidden = !Self.showsIcon(icon, fallback: fallback)
        emoji.isHidden = true
        switch icon {
        case let .emoji(text)?:
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
            imageView.image = fallback.map { NSImage.icon($0, size: Metrics.smallIconSize, style: .line) }
            imageView.isHidden = fallback == nil
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
            if case let .swatch(color)? = icon {
                swatch.isHidden = false
                swatch.backgroundColor = SidebarStyle.color(color).cgColor
            } else {
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
        let side = SidebarStyle.dotSize
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swatch.frame = rect
        swatch.cornerRadius = side / 2
        CATransaction.commit()
        needsDisplay = true
    }
}

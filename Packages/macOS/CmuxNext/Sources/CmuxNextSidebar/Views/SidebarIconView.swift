import AppKit
import CmuxNextDesign
import QuartzCore

/// Workspace icon, shown only when the user chose one: an SF Symbol, or a
/// color (a small dot in full rows, a swatch with a monogram in icons-only
/// rows). Icons-only rows without a chosen icon show the title's first
/// letter as plain text.
final class SidebarIconView: NSView {
    private let imageView = NSImageView()
    private let swatch = CALayer()
    private let monogram = NSTextField(labelWithString: "")
    private var icon: WorkspaceIcon?
    private var compact = false

    /// Full rows reserve room only for a chosen icon.
    static func showsIcon(_ icon: WorkspaceIcon?, compact: Bool) -> Bool {
        compact || icon != nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        monogram.alignment = .center
        addSubview(imageView)
        addSubview(monogram)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(icon: WorkspaceIcon?, title: String, compact: Bool) {
        self.icon = icon
        self.compact = compact
        isHidden = !Self.showsIcon(icon, compact: compact)
        monogram.stringValue = title.first.map { String($0).uppercased() } ?? ""
        switch icon {
        case let .symbol(name, tint)?:
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.contentTintColor = tint.map(SidebarStyle.color) ?? Palette.textSecondary
            imageView.isHidden = false
            monogram.isHidden = true
        case .swatch?:
            imageView.isHidden = true
            monogram.isHidden = !compact
            monogram.font = NSFont.systemFont(ofSize: Typography.caption.pointSize - Metrics.space1, weight: .bold)
            monogram.textColor = Palette.textOnPrimary
        case nil:
            imageView.isHidden = true
            monogram.isHidden = !compact
            monogram.font = SidebarStyle.titleUnreadFont
            monogram.textColor = Palette.textSecondary
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case let .swatch(color)? = icon {
            swatch.isHidden = false
            swatch.backgroundColor = resolvedCGColor(SidebarStyle.color(color))
        } else {
            swatch.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        // Full rows: a dot. Icons-only rows: a swatch that carries a letter.
        let side = compact ? SidebarStyle.swatchSize : SidebarStyle.dotSize
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swatch.frame = rect
        swatch.cornerRadius = compact ? side * 0.28 : side / 2
        CATransaction.commit()
        let size = monogram.intrinsicContentSize
        monogram.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
        needsDisplay = true
    }
}

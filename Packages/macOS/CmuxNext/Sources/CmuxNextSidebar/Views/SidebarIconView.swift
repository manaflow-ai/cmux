import AppKit
import CmuxNextDesign
import QuartzCore

/// Workspace icon, shown only when the user chose one: an SF Symbol, or a
/// color shown as a small dot.
final class SidebarIconView: NSView {
    private let imageView = NSImageView()
    private let swatch = CALayer()
    private var icon: WorkspaceIcon?

    /// Rows reserve room only for a chosen icon.
    static func showsIcon(_ icon: WorkspaceIcon?) -> Bool {
        icon != nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(icon: WorkspaceIcon?) {
        self.icon = icon
        isHidden = !Self.showsIcon(icon)
        switch icon {
        case let .symbol(name, tint)?:
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.isHidden = false
        case .swatch?, nil:
            imageView.isHidden = true
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            if case let .symbol(_, tint)? = icon {
                imageView.contentTintColor = tint.map(SidebarStyle.color) ?? Palette.textSecondary
            }
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

import AppKit
import CmuxNextDesign
import QuartzCore

/// Workspace icon: an SF Symbol or a color swatch with a monogram.
final class SidebarIconView: NSView {
    private let imageView = NSImageView()
    private let swatch = CALayer()
    private let monogram = NSTextField(labelWithString: "")
    private var icon: WorkspaceIcon = .symbol("terminal")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        monogram.font = NSFont.systemFont(ofSize: Typography.caption.pointSize - Metrics.space1, weight: .bold)
        monogram.textColor = .white
        monogram.alignment = .center
        addSubview(imageView)
        addSubview(monogram)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(icon: WorkspaceIcon, title: String) {
        self.icon = icon
        switch icon {
        case let .symbol(name, tint):
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.contentTintColor = tint.map(SidebarStyle.color) ?? Palette.textSecondary
            imageView.isHidden = false
            monogram.isHidden = true
        case .swatch:
            monogram.font = NSFont.systemFont(ofSize: Typography.caption.pointSize - Metrics.space1, weight: .bold)
            imageView.isHidden = true
            monogram.isHidden = false
            monogram.stringValue = title.first.map { String($0).uppercased() } ?? ""
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case let .swatch(color) = icon {
            swatch.isHidden = false
            swatch.backgroundColor = SidebarStyle.color(color).cgColor
        } else {
            swatch.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let side = SidebarStyle.swatchSize
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swatch.frame = rect
        swatch.cornerRadius = side * 0.28
        CATransaction.commit()
        let size = monogram.intrinsicContentSize
        monogram.frame = NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height)
        needsDisplay = true
    }
}

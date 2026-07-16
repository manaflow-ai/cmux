import AppKit
import QuartzCore

/// Fixed-hierarchy unread badge shared by the native workspace and group cells.
/// The label is retained across reuse; configuration only changes its value and
/// colors, avoiding per-update view allocation.
@MainActor
final class SidebarAppKitBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var fillColor: NSColor = .controlAccentColor
    private var badgeHeight: CGFloat = SidebarAppKitCellMetrics.accessorySide

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        guard !isHidden else { return .zero }
        return NSSize(
            width: max(badgeHeight, ceil(label.intrinsicContentSize.width) + 10),
            height: badgeHeight
        )
    }

    func configure(
        count: Int,
        fillColor: NSColor,
        textColor: NSColor,
        font: NSFont,
        height: CGFloat
    ) {
        guard count > 0 else {
            resetForReuse()
            return
        }
        self.fillColor = fillColor
        badgeHeight = max(12, height)
        label.stringValue = String(count)
        label.font = font
        label.textColor = textColor
        isHidden = false
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyFillColor()
    }

    func resetForReuse() {
        label.stringValue = ""
        isHidden = true
        invalidateIntrinsicContentSize()
        layer?.backgroundColor = nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.height, badgeHeight) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFillColor()
    }

    private func applyFillColor() {
        guard !isHidden else { return }
        var resolved = fillColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = fillColor.usingColorSpace(.deviceRGB)?.cgColor ?? fillColor.cgColor
        }
        layer?.backgroundColor = resolved
    }
}

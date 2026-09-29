import AppKit
import CmuxNextDesign

/// Compact custom titlebar above the content column: the workspace title,
/// centered, secondary text. Dragging it moves the window; double-click
/// zooms like a native titlebar.
final class TitlebarView: NSView {
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.bodyEmphasized
        label.textColor = Palette.textSecondary
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space5),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { super.mouseUp(with: event) }
    }
}

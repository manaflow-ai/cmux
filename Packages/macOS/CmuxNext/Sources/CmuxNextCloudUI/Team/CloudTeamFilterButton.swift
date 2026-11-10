import AppKit
import CmuxNextDesign

/// One of the Team section's four filters: its name, on the selection fill while it is the shown one.
@MainActor
final class CloudTeamFilterButton: NSView {
    /// Runs on a click (and on VoiceOver's press).
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            setAccessibilitySelected(isSelected)
            tint()
        }
    }

    var colors: CloudTeamColors { didSet { if colors != oldValue { tint() } } }
    private let label: NSTextField
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 3

    init(title: String, colors: CloudTeamColors) {
        label = NSTextField(labelWithString: title)
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = Typography.caption
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        tint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var title: String { label.stringValue }

    /// The size the button asks for: its name plus the padding around it.
    var preferredSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + Self.horizontalPadding * 2, height: ceil(text.height) + Self.verticalPadding * 2)
    }

    private func tint() {
        label.textColor = isSelected ? colors.text : colors.secondary
        layer?.backgroundColor = isSelected ? colors.selection.cgColor : nil
    }

    override func layout() {
        super.layout()
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: Self.horizontalPadding, y: (bounds.height - text.height) / 2,
                             width: max(0, bounds.width - Self.horizontalPadding * 2), height: text.height)
    }

    /// The whole button takes the click (its label never does).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    /// Taken here, so nothing under it starts a press.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

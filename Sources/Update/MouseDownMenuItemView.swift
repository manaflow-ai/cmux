import AppKit

@MainActor
final class MouseDownMenuItemView: NSView {
    private static let defaultWidth: CGFloat = 260
    private static let labelHorizontalPadding: CGFloat = 14
    private static let highlightHorizontalInset: CGFloat = 5
    private static let highlightVerticalInset: CGFloat = 2
    private static let highlightCornerRadius: CGFloat = 5

    private let titleLabel = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
            titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        }
    }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.defaultWidth,
            height: Self.nativeMenuItemRowHeight()
        ))
        // NSMenu sizes to its widest item; let this custom view stretch so its
        // highlight spans the full menu like a native item.
        autoresizingMask = [.width]
        wantsLayer = true
        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelHorizontalPadding),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.labelHorizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: Self.highlightHorizontalInset, dy: Self.highlightVerticalInset),
            xRadius: Self.highlightCornerRadius,
            yRadius: Self.highlightCornerRadius
        ).fill()
    }

    static func nativeMenuItemRowHeight() -> CGFloat {
        let oneItemMenu = NSMenu()
        oneItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))

        let twoItemMenu = NSMenu()
        twoItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        twoItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))

        let rowHeight = twoItemMenu.size.height - oneItemMenu.size.height
        guard rowHeight.isFinite, rowHeight > 0 else {
            let menuFont = NSFont.menuFont(ofSize: 0)
            return ceil(menuFont.ascender - menuFont.descender + menuFont.leading)
        }
        return rowHeight
    }
}

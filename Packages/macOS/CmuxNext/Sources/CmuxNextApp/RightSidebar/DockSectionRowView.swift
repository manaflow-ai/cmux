import AppKit
import CmuxNextDesign

/// One docked column in the Dock section: the edge's symbol, the selected
/// tab's title and an Undock button. A click elsewhere on the row focuses
/// the column's first pane. Holds a value snapshot and the action bundle only.
final class DockSectionRowView: NSView {
    let row: DockSectionRow
    private let actions: DockSectionActions

    init(row: DockSectionRow, actions: DockSectionActions) {
        self.row = row
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.rightSidebar.dock.row.\(row.id)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)

        let icon = ThemedImageView(image: NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.ink = .secondary
        let title = ThemedLabel(labelWithString: row.title)
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let undock = NSButton(title: RightSidebarStrings.undock, target: self, action: #selector(undockClicked))
        undock.isBordered = false
        undock.font = Typography.body
        undock.setAccessibilityIdentifier("cmux.rightSidebar.dock.undock.\(row.id)")
        undock.setContentHuggingPriority(.required, for: .horizontal)

        let line = NSStackView(views: [icon, title, NSView(), undock])
        line.orientation = .horizontal
        line.spacing = Metrics.panelInset
        line.edgeInsets = NSEdgeInsets(top: 3, left: Metrics.panelInset, bottom: 3, right: Metrics.panelInset)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        actions.focus(row.pane)
    }

    override func accessibilityPerformPress() -> Bool {
        actions.focus(row.pane)
        return true
    }

    @objc private func undockClicked() { actions.undock(row.id) }
}

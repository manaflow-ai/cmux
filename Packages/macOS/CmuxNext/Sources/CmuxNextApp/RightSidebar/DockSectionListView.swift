import AppKit
import CmuxNextDesign

/// The Dock section: the shown screen's docked columns; a click focuses one,
/// Undock lets it scroll again. AppKit (plans/cmux-next/no-swiftui-DESIGN.md):
/// rows take value snapshots and the action bundle only, and are rebuilt
/// only when the rows change.
final class DockSectionListView: NSView {
    private let actions: DockSectionActions
    private let stack = NSStackView()
    private let rowStack = NSStackView()
    private let empty = ThemedLabel(wrappingLabelWithString: RightSidebarStrings.dockEmpty)
    private let emptyBox: DockSectionInsetView
    private(set) var rows: [DockSectionRow]?

    init(actions: DockSectionActions) {
        self.actions = actions
        emptyBox = DockSectionInsetView(empty, inset: Metrics.panelInset, fills: true)
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2

        empty.font = Typography.caption
        empty.ink = .secondary
        empty.preferredMaxLayoutWidth = RightSidebarModel.width - 2 * Metrics.panelInset
        empty.setAccessibilityIdentifier("cmux.rightSidebar.dock.empty")

        let dockFocused = NSButton(title: RightSidebarStrings.dockFocused, target: self, action: #selector(dockFocusedClicked))
        dockFocused.isBordered = false
        dockFocused.font = Typography.body
        dockFocused.setAccessibilityIdentifier("cmux.rightSidebar.dock.dockFocused")
        let dockBox = DockSectionInsetView(dockFocused, inset: Metrics.panelInset)

        for view in [emptyBox, rowStack, dockBox] as [NSView] { stack.addArrangedSubview(view) }
        for view in [emptyBox, rowStack] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        show([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `next`; does nothing when the rows did not change.
    func show(_ next: [DockSectionRow]) {
        guard next != rows else { return }
        rows = next
        for view in rowStack.arrangedSubviews { view.removeFromSuperview() }
        for row in next {
            let view = DockSectionRowView(row: row, actions: actions)
            rowStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        emptyBox.isHidden = !next.isEmpty
        empty.isHidden = !next.isEmpty
        rowStack.isHidden = next.isEmpty
    }

    @objc private func dockFocusedClicked() { actions.dockFocused() }
}

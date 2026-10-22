import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// One checklist item on the Todo page: its state mark (click toggles complete), its text
/// (double-click edits; Return commits, Escape cancels), how many images it has, and a menu of its
/// actions. Holds a value snapshot and the action bundle only.
final class WorkspaceTodoRow: NSView, NSTextFieldDelegate, NSMenuDelegate {
    let item: WorkspaceChecklistItem
    private let actions: WorkspaceTodoRowActions
    private let label = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private(set) var isEditing = false

    init(item: WorkspaceChecklistItem, isEditing: Bool, actions: WorkspaceTodoRowActions) {
        self.item = item
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let done = item.state == .done

        let mark = NSButton(image: NSImage(systemSymbolName: Self.symbol(item.state), accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(toggleClicked))
        mark.isBordered = false
        mark.contentTintColor = done ? Palette.litGlyph : .secondaryLabelColor
        mark.setAccessibilityLabel(WorkspaceChecklistStrings.toggle)
        mark.setAccessibilityIdentifier("cmux.todo.toggle")
        mark.setContentHuggingPriority(.required, for: .horizontal)

        var attributes: [NSAttributedString.Key: Any] = [.font: Typography.body, .foregroundColor: done ? NSColor.secondaryLabelColor : NSColor.labelColor]
        if done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        label.attributedStringValue = NSAttributedString(string: item.text, attributes: attributes)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("cmux.todo.text")

        field.font = Typography.body
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = WorkspaceChecklistStrings.addPlaceholder
        field.delegate = self
        field.target = self
        field.action = #selector(commitClicked)
        field.setAccessibilityIdentifier("cmux.todo.edit")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [mark, label, field]
        if !item.attachments.isEmpty {
            let images = NSButton(title: "\(item.attachments.count)", image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage(),
                                  target: nil, action: nil)
            images.isBordered = false
            images.imagePosition = .imageLeading
            images.contentTintColor = .secondaryLabelColor
            images.themedToolTip = item.attachments.map(\.name).joined(separator: "\n")
            images.setContentHuggingPriority(.required, for: .horizontal)
            views.append(images)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let menu = NSMenu()
        menu.delegate = self
        self.menu = menu
        show(editing: isEditing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func show(editing: Bool) {
        isEditing = editing
        label.isHidden = editing
        field.isHidden = !editing
        if editing {
            field.stringValue = item.text
            window?.makeFirstResponder(field)
        }
    }

    /// Shows the text field over the item (the double click and the Edit menu item).
    func beginEditing() {
        actions.beginEdit(item.id)
        show(editing: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isEditing { window?.makeFirstResponder(field) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !isEditing { beginEditing() } else { super.mouseDown(with: event) }
    }

    @objc private func toggleClicked() { actions.toggle(item.id) }

    @objc private func commitClicked() {
        guard isEditing else { return }
        show(editing: false)
        actions.commitEdit(item.id, field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        show(editing: false)
        actions.cancelEdit()
        return true
    }

    /// The row menu's commands, by menu item tag.
    private enum Command: Int {
        case inProgress, todo, complete, edit, attach, remove
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ command: Command) {
            let entry = NSMenuItem(title: title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = command.rawValue
            menu.addItem(entry)
        }
        if item.state != .inProgress { add(WorkspaceChecklistStrings.markInProgress, .inProgress) }
        if item.state == .done { add(WorkspaceChecklistStrings.markTodo, .todo) } else { add(WorkspaceChecklistStrings.complete, .complete) }
        add(WorkspaceChecklistStrings.edit, .edit)
        add(WorkspaceChecklistStrings.attachImages, .attach)
        menu.addItem(.separator())
        add(WorkspaceChecklistStrings.remove, .remove)
    }

    @objc private func menuPicked(_ entry: NSMenuItem) {
        switch Command(rawValue: entry.tag) {
        case .inProgress: actions.setState(item.id, .inProgress)
        case .todo: actions.setState(item.id, .todo)
        case .complete: actions.setState(item.id, .done)
        case .edit: beginEditing()
        case .attach: actions.attachImages(item.id)
        case .remove: actions.remove(item.id)
        case nil: break
        }
    }

    static func symbol(_ state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

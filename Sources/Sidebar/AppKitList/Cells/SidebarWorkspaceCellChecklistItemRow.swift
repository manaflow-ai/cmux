import AppKit
import CmuxWorkspaces
import Foundation

/// One checklist item line, shared by the inline expansion and the popover:
/// checkbox, wrapping text (click to edit), hover-revealed delete button, and
/// the Edit / Mark In Progress / Remove context menu.
final class SidebarWorkspaceCellChecklistItemRowView: NSView {
    struct Appearance {
        let checkboxPointSize: CGFloat
        let removePointSize: CGFloat
        let textFont: NSFont
        let editFontSize: CGFloat
        let primaryColor: NSColor
        let secondaryColor: NSColor
    }

    private let row = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4, alignment: .top)
    private let checkboxButton = SidebarWorkspaceCellButton()
    private let checkboxBox: SidebarWorkspaceCellFirstLineBox
    private let textLabel = SidebarWorkspaceCellLabel()
    private let editButton = SidebarWorkspaceCellButton()
    private let textContainer = NSView()
    private let editFieldContainer = NSView()
    private var editField: FocusGrabbingTextField?
    private var editCoordinator: ChecklistInputField.Coordinator?
    private let removeButton = SidebarWorkspaceCellButton()
    private let removeBox: SidebarWorkspaceCellFirstLineBox

    private var item: WorkspaceChecklistItem?
    private var setState: ((UUID, WorkspaceChecklistItem.State) -> Void)?
    private var remove: ((UUID) -> Void)?
    private var beginEdit: ((UUID) -> Void)?
    private var finishEdit: ((UUID, String?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false

    override init(frame frameRect: NSRect) {
        checkboxBox = SidebarWorkspaceCellFirstLineBox(child: checkboxButton)
        removeBox = SidebarWorkspaceCellFirstLineBox(child: removeButton)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("SidebarChecklistItemRow")

        textLabel.wrapsText = true
        textLabel.maximumNumberOfLines = 0

        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(textLabel)
        editButton.imagePosition = .noImage
        editButton.title = ""
        editButton.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.beginEdit?(item.id)
        }
        textContainer.addSubview(editButton)
        editFieldContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainer.addSubview(editFieldContainer)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textLabel.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            editButton.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            editButton.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            editButton.topAnchor.constraint(equalTo: textContainer.topAnchor),
            editButton.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            editFieldContainer.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            editFieldContainer.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            editFieldContainer.topAnchor.constraint(equalTo: textContainer.topAnchor),
            editFieldContainer.bottomAnchor.constraint(lessThanOrEqualTo: textContainer.bottomAnchor),
        ])

        checkboxButton.setAccessibilityIdentifier("SidebarChecklistItemCheckbox")
        checkboxButton.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            let next: WorkspaceChecklistItem.State = item.state == .completed ? .pending : .completed
            self.setState?(item.id, next)
        }
        removeButton.setAccessibilityIdentifier("SidebarChecklistRemoveItemButton")
        removeButton.toolTip = String(
            localized: "sidebar.checklist.removeItemTooltip",
            defaultValue: "Remove item"
        )
        removeButton.onPress = { [weak self] in
            guard let self, let item = self.item else { return }
            self.remove?(item.id)
        }

        row.addArrangedSubview(checkboxBox)
        row.addArrangedSubview(textContainer)
        row.addArrangedSubview(removeBox)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // swiftlint:disable:next function_parameter_count
    func update(
        item: WorkspaceChecklistItem,
        appearance: Appearance,
        isEditing: Bool,
        setState: @escaping (UUID, WorkspaceChecklistItem.State) -> Void,
        remove: @escaping (UUID) -> Void,
        beginEdit: @escaping (UUID) -> Void,
        finishEdit: @escaping (UUID, String?) -> Void
    ) {
        self.item = item
        self.setState = setState
        self.remove = remove
        self.beginEdit = beginEdit
        self.finishEdit = finishEdit

        let isCompleted = item.state == .completed
        let firstLineCenter = (appearance.textFont.ascender - appearance.textFont.descender) / 2

        checkboxButton.image = SidebarWorkspaceCellSymbols.image(
            Self.checkboxSymbolName(for: item.state),
            pointSize: appearance.checkboxPointSize
        )
        checkboxButton.contentTintColor = isCompleted
            ? appearance.secondaryColor
            : appearance.primaryColor
        checkboxButton.toolTip = isCompleted
            ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
            : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
        checkboxBox.setFirstLineCenter(firstLineCenter, childHeight: appearance.checkboxPointSize)

        if isEditing {
            textLabel.isHidden = true
            editButton.isHidden = true
            editButton.isInteractionEnabled = false
            editFieldContainer.isHidden = false
            installEditField(item: item, appearance: appearance)
        } else {
            removeEditField()
            editFieldContainer.isHidden = true
            textLabel.isHidden = false
            editButton.isHidden = false
            editButton.isInteractionEnabled = true
            var attributes: [NSAttributedString.Key: Any] = [
                .font: appearance.textFont,
                .foregroundColor: isCompleted
                    ? SidebarWorkspaceCellStyle.dimmed(appearance.secondaryColor, 0.6)
                    : appearance.primaryColor,
            ]
            if isCompleted {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            textLabel.attributedStringValue = NSAttributedString(string: item.text, attributes: attributes)
        }

        removeButton.image = SidebarWorkspaceCellSymbols.image(
            "xmark.circle.fill",
            pointSize: appearance.removePointSize
        )
        removeButton.contentTintColor = appearance.secondaryColor
        removeBox.setFirstLineCenter(firstLineCenter, childHeight: appearance.removePointSize + 8)
        applyHoverState()

        menu = buildContextMenu(for: item)
    }

    private func installEditField(item: WorkspaceChecklistItem, appearance: Appearance) {
        removeEditField()
        let field = FocusGrabbingTextField(string: item.text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = SidebarWorkspaceCellFonts.system(appearance.editFontSize)
        field.textColor = appearance.primaryColor
        field.caretColor = appearance.primaryColor
        field.placeholderString = String(
            localized: "sidebar.checklist.editItemPlaceholder",
            defaultValue: "Item text"
        )
        field.selectsAllOnFocus = true
        field.setAccessibilityIdentifier("SidebarChecklistEditItemField")
        let itemId = item.id
        let coordinator = ChecklistInputField.Coordinator(
            onCommit: { [weak self] text in self?.finishEdit?(itemId, text) },
            onCancel: { [weak self] in self?.finishEdit?(itemId, nil) }
        )
        field.delegate = coordinator
        editCoordinator = coordinator
        editField = field
        editFieldContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: editFieldContainer.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: editFieldContainer.trailingAnchor),
            field.topAnchor.constraint(equalTo: editFieldContainer.topAnchor),
            field.bottomAnchor.constraint(equalTo: editFieldContainer.bottomAnchor),
            field.heightAnchor.constraint(equalToConstant: appearance.editFontSize + 4),
        ])
    }

    private func removeEditField() {
        guard let field = editField else { return }
        field.delegate = nil
        field.removeFromSuperview()
        editField = nil
        editCoordinator = nil
    }

    private static func checkboxSymbolName(for state: WorkspaceChecklistItem.State) -> String {
        switch state {
        case .pending: return "square"
        case .inProgress: return "minus.square"
        case .completed: return "checkmark.square.fill"
        }
    }

    // MARK: Hover-revealed delete button

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyHoverState()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyHoverState()
    }

    private func applyHoverState() {
        removeButton.alphaValue = isPointerInside ? 1 : 0
        removeButton.isInteractionEnabled = isPointerInside
    }

    // MARK: Context menu

    private func buildContextMenu(for item: WorkspaceChecklistItem) -> NSMenu {
        let menu = NSMenu()
        let edit = NSMenuItem(
            title: String(localized: "sidebar.checklist.editItem", defaultValue: "Edit"),
            action: #selector(contextEdit),
            keyEquivalent: ""
        )
        edit.target = self
        menu.addItem(edit)
        if item.state != .inProgress {
            let inProgress = NSMenuItem(
                title: String(
                    localized: "sidebar.checklist.markInProgress",
                    defaultValue: "Mark In Progress"
                ),
                action: #selector(contextMarkInProgress),
                keyEquivalent: ""
            )
            inProgress.target = self
            menu.addItem(inProgress)
        }
        let removeItem = NSMenuItem(
            title: String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove"),
            action: #selector(contextRemove),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
        return menu
    }

    @objc private func contextEdit() {
        guard let item else { return }
        beginEdit?(item.id)
    }

    @objc private func contextMarkInProgress() {
        guard let item else { return }
        setState?(item.id, .inProgress)
    }

    @objc private func contextRemove() {
        guard let item else { return }
        remove?(item.id)
    }
}

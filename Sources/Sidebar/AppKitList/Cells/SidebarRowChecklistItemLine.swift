import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Item line

/// One checklist item row: state checkbox, wrapping item text (tap-to-edit
/// swaps in a focused field), always-visible attachment menu, and a
/// hover-revealed remove button in a reserved trailing slot. Right-click
/// offers Edit / Mark In Progress / Remove (legacy context menu).
@MainActor
final class SidebarRowChecklistItemLine: NSView {
    private let checkbox = SidebarHeaderGlyphButton()
    private let textLabel = SidebarRowTextView(lines: 0)
    private let textClickOverlay = SidebarRowChecklistTransparentButton()
    private var editField: FocusGrabbingTextField?
    private var editFieldBridge: SidebarRowChecklistFieldBridge?
    private var editingItemId: UUID?
    private let attachmentButton = SidebarRowChecklistAttachmentButton()
    private let removeButton = SidebarHeaderGlyphButton()
    private var trackingArea: NSTrackingArea?
    private var item: WorkspaceChecklistItem?
    private var model: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var isEditing = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(checkbox)
        addSubview(textLabel)
        addSubview(textClickOverlay)
        addSubview(attachmentButton)
        removeButton.isHidden = true
        addSubview(removeButton)
        setAccessibilityIdentifier("SidebarChecklistItemRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        secondary: NSColor,
        isEditing: Bool,
        actions: SidebarAppKitRowActions
    ) {
        if self.item?.id != item.id {
            // Pooled-line reuse: never carry a hover-revealed remove button
            // to a different item (the tracking area re-derives on the next
            // pointer move).
            removeButton.isHidden = true
        }
        self.item = item
        self.model = model
        self.actions = actions

        let completed = item.state == .completed
        let symbol: String
        switch item.state {
        case .completed: symbol = "checkmark.square.fill"
        case .inProgress: symbol = "minus.square"
        default: symbol = "square"
        }
        checkbox.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol, pointSize: model.scaled(8), weight: nil
        )
        checkbox.contentTintColor = completed ? secondary : primary
        checkbox.toolTip = completed
            ? String(localized: "sidebar.checklist.uncheckTooltip", defaultValue: "Mark as pending")
            : String(localized: "sidebar.checklist.checkTooltip", defaultValue: "Mark as completed")
        checkbox.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            let next: WorkspaceChecklistItem.State = item.state == .completed ? .pending : .completed
            self.actions?.checklistSetItemState(item.id, next)
        }

        let itemFont = NSFont.systemFont(ofSize: model.scaled(10))
        // Keep the field's `font` in sync with the attributed text: the
        // first-line-center math reads it.
        textLabel.font = itemFont
        if completed {
            // Legacy completed treatment: secondary color at 0.6 opacity
            // (multiplied, like SwiftUI `.opacity`) plus strikethrough.
            textLabel.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .font: itemFont,
                    .foregroundColor: secondary.withAlphaComponent(secondary.alphaComponent * 0.6),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
        } else {
            textLabel.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .font: itemFont,
                    .foregroundColor: primary,
                ]
            )
        }
        textClickOverlay.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            self.actions?.onBeginChecklistItemEdit(item.id)
        }

        reconcileEditField(
            item: item,
            model: model,
            primary: primary,
            isEditing: isEditing,
            actions: actions
        )

        attachmentButton.configure(
            item: item,
            model: model,
            color: secondary,
            actions: actions
        )

        removeButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "xmark.circle.fill", pointSize: model.scaled(9), weight: nil
        )
        removeButton.contentTintColor = secondary
        removeButton.toolTip = String(localized: "sidebar.checklist.removeItemTooltip", defaultValue: "Remove item")
        removeButton.onClick = { [weak self] in
            guard let self, let item = self.item else { return }
            self.actions?.checklistRemoveItem(item.id)
        }
        needsLayout = true
    }

    private func reconcileEditField(
        item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        primary: NSColor,
        isEditing: Bool,
        actions: SidebarAppKitRowActions?
    ) {
        self.isEditing = isEditing
        textLabel.isHidden = isEditing
        textClickOverlay.isHidden = isEditing
        guard isEditing else {
            editField?.removeFromSuperview()
            editField = nil
            editFieldBridge = nil
            editingItemId = nil
            return
        }
        guard editField == nil || editingItemId != item.id else {
            // Retained editor: keep the draft but follow the row's current
            // presentation (palette flips with selection; fonts with scale).
            editField?.font = .systemFont(ofSize: 11 * model.fontScale)
            editField?.textColor = primary
            editField?.caretColor = primary
            return
        }
        editField?.removeFromSuperview()
        // Fresh field per edit session (legacy recreates via view identity):
        // `FocusGrabbingTextField` takes first responder when it attaches to
        // the window, and select-all marks the edit variant.
        let field = SidebarRowChecklistFocusField(string: item.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 11 * model.fontScale)
        field.textColor = primary
        field.caretColor = primary
        field.placeholderString = String(localized: "sidebar.checklist.editItemPlaceholder", defaultValue: "Item text")
        field.selectsAllOnFocus = true
        field.setAccessibilityLabel(field.placeholderString ?? "")
        field.setAccessibilityIdentifier("SidebarChecklistEditItemField")
        // Capture the edited item's identity and its workspace's action
        // bundle at field-creation time: the pooled line's `self.item`/
        // `self.actions` are overwritten by reconfiguration (ordering
        // changes, cell reuse) BEFORE the old editor tears down, and a
        // teardown-triggered focus-loss commit must not write the draft
        // into whichever item the line shows next.
        let editedItemId = item.id
        guard let editActions = actions else { return }
        let bridge = SidebarRowChecklistFieldBridge(
            onCommit: { text in
                // Enter (or focus loss) commits trimmed text; empty keeps the
                // old text (legacy `commitItemEdit`). Ends only THIS item's
                // session: a torn-down editor's focus-loss commit must not
                // clear an edit the user just started on another item.
                editActions.onEndChecklistItemEdit(editedItemId)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                editActions.checklistEditItem(editedItemId, trimmed)
            },
            onCancel: {
                editActions.onEndChecklistItemEdit(editedItemId)
            }
        )
        field.delegate = bridge
        editFieldBridge = bridge
        editField = field
        editingItemId = item.id
        // Valid frame BEFORE the window attach (see the add row's comment):
        // a zero-frame focus grab mis-sizes the field editor's dark box.
        if let metrics = metrics(width: max(bounds.width, 100)) {
            let fieldHeight = 11 * model.fontScale + 4
            field.frame = NSRect(
                x: metrics.checkbox.width + 4, y: 0,
                width: metrics.textWidth, height: fieldHeight
            )
        }
        addSubview(field)
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(field)
        needsLayout = true
    }

    /// Legacy `firstLineCenterOffset`: accessories center on the item text's
    /// FIRST line. The offset font intentionally approximates the item font
    /// without global magnification, matching the SwiftUI implementation.
    private func firstLineCenter(model: SidebarWorkspaceRowModel, itemFont: NSFont) -> CGFloat {
        let approximation = NSFont.systemFont(ofSize: 10 * model.fontScale)
        return itemFont.ascender - (approximation.ascender + approximation.descender) / 2
    }

    private func metrics(width: CGFloat) -> (
        checkbox: NSSize, attach: NSSize, removeSlot: CGFloat, textWidth: CGFloat
    )? {
        guard let model else { return nil }
        let checkboxSize = checkbox.glyphImage?.size ?? .zero
        let attachSize = attachmentButton.measuredSize()
        let removeSlot = 9 * model.fontScale + 8
        // HStack(spacing: 4): checkbox·text·Spacer·attachment·remove — the
        // spacer contributes two spacings even at zero width.
        let textWidth = max(10, width - checkboxSize.width - 4 - 8 - attachSize.width - 4 - removeSlot)
        return (checkboxSize, attachSize, removeSlot, textWidth)
    }

    /// SwiftUI's first-baseline HStack grows the row so the accessories
    /// (whose optical centers sit on the first text line) fit fully — the
    /// text shifts DOWN when an accessory is taller than the space above the
    /// first-line center. `textTop` is that shift.
    private func verticalMetrics(
        model: SidebarWorkspaceRowModel,
        metrics: (checkbox: NSSize, attach: NSSize, removeSlot: CGFloat, textWidth: CGFloat)
    ) -> (textTop: CGFloat, lineCenter: CGFloat) {
        let itemFont = textLabel.font ?? NSFont.systemFont(ofSize: model.scaled(10))
        let center = firstLineCenter(model: model, itemFont: itemFont)
        let maxAccessoryHalf = max(
            metrics.checkbox.height / 2,
            metrics.attach.height / 2,
            metrics.removeSlot / 2
        )
        let textTop = max(0, maxAccessoryHalf - center)
        return (textTop, textTop + center)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !isHidden, let model, let metrics = metrics(width: width) else { return 0 }
        let vertical = verticalMetrics(model: model, metrics: metrics)
        let contentHeight: CGFloat
        if isEditing {
            contentHeight = 11 * model.fontScale + 4
        } else {
            contentHeight = textLabel.measuredHeight(width: metrics.textWidth)
        }
        let accessoryExtent = vertical.lineCenter + max(
            metrics.checkbox.height / 2,
            metrics.attach.height / 2,
            metrics.removeSlot / 2
        )
        return ceil(max(vertical.textTop + contentHeight, accessoryExtent))
    }

    override func layout() {
        super.layout()
        guard let model, let metrics = metrics(width: bounds.width) else { return }
        let vertical = verticalMetrics(model: model, metrics: metrics)
        checkbox.frame = NSRect(
            x: 0, y: vertical.lineCenter - metrics.checkbox.height / 2,
            width: metrics.checkbox.width, height: metrics.checkbox.height
        )
        let textX = metrics.checkbox.width + 4
        if isEditing, let editField {
            let fieldHeight = 11 * model.fontScale + 4
            editField.frame = NSRect(
                x: textX, y: max(0, vertical.lineCenter - fieldHeight / 2),
                width: metrics.textWidth, height: fieldHeight
            )
        } else {
            let textHeight = textLabel.measuredHeight(width: metrics.textWidth)
            textLabel.frame = NSRect(
                x: textX, y: vertical.textTop,
                width: metrics.textWidth, height: textHeight
            )
            textClickOverlay.frame = textLabel.frame
        }
        removeButton.frame = NSRect(
            x: bounds.width - metrics.removeSlot,
            y: vertical.lineCenter - metrics.removeSlot / 2,
            width: metrics.removeSlot, height: metrics.removeSlot
        )
        attachmentButton.frame = NSRect(
            x: removeButton.frame.minX - 4 - metrics.attach.width,
            y: vertical.lineCenter - metrics.attach.height / 2,
            width: metrics.attach.width, height: metrics.attach.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        removeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        removeButton.isHidden = true
    }

    /// Reuse teardown: drop the item, action bundle, editor, and click
    /// closures so a hidden pooled line stops retaining its previous
    /// workspace.
    func resetForReuse() {
        guard item != nil || actions != nil || editField != nil else { return }
        editField?.removeFromSuperview()
        editField = nil
        editFieldBridge = nil
        editingItemId = nil
        isEditing = false
        item = nil
        model = nil
        actions = nil
        checkbox.onClick = nil
        removeButton.onClick = nil
        removeButton.isHidden = true
        textClickOverlay.onClick = nil
        textLabel.stringValue = ""
        attachmentButton.resetForReuse()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let actions else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Freeze the workspace-bound closure at build time: NSMenu tracking
        // allows this pooled line to be recycled before the selection fires.
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.editItem", defaultValue: "Edit")
        ) { [beginEdit = actions.onBeginChecklistItemEdit] in
            beginEdit(item.id)
        })
        if item.state != .inProgress {
            menu.addItem(SidebarRowClosureMenuItem(
                title: String(localized: "sidebar.checklist.markInProgress", defaultValue: "Mark In Progress")
            ) { [actions] in
                actions.checklistSetItemState(item.id, .inProgress)
            })
        }
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.removeItem", defaultValue: "Remove")
        ) { [actions] in
            actions.checklistRemoveItem(item.id)
        })
        return menu
    }
}

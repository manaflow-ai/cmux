import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Add row

/// The trailing add affordance under the inline expansion: a ghost
/// "+ Add item" row that arms into a `plus.circle` + focused text field.
/// Enter commits and re-arms a fresh empty field; Esc dismisses.
@MainActor
final class SidebarRowChecklistAddRow: NSView {
    private let ghostButton = SidebarRowChecklistGhostAddButton()
    private let plusIconView = NSImageView()
    private var addField: FocusGrabbingTextField?
    private var addFieldBridge: SidebarRowChecklistFieldBridge?
    private var lastArmToken = 0
    private var lastArmWorkspaceId: UUID?
    private var isAdding = false
    private var model: SidebarWorkspaceRowModel?
    private var primary: NSColor = .labelColor
    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(ghostButton)
        plusIconView.imageScaling = .scaleProportionallyDown
        plusIconView.isHidden = true
        addSubview(plusIconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        workspaceId: UUID,
        model: SidebarWorkspaceRowModel,
        secondary: NSColor,
        primary: NSColor,
        isAdding: Bool,
        armToken: Int,
        onBeginAdding: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.primary = primary
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.isAdding = isAdding

        ghostButton.isHidden = isAdding
        if !isAdding {
            // A `plus` glyph plus "Add item" (legacy ghost row: the add row
            // never reads as a real unchecked item).
            ghostButton.configure(
                iconPointSize: model.scaled(7),
                title: String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"),
                font: .systemFont(ofSize: model.scaled(10)),
                color: secondary,
                onClick: onBeginAdding
            )
        }

        plusIconView.isHidden = !isAdding
        if isAdding {
            plusIconView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "plus.circle", pointSize: model.scaled(8), weight: nil
            )
            plusIconView.contentTintColor = secondary
            // Key the armed editor by workspace AND token: per-workspace
            // tokens commonly collide (both start at 1), and a recycled cell
            // must never keep the previous workspace's draft or bridge.
            if addField == nil || armToken != lastArmToken || workspaceId != lastArmWorkspaceId {
                rearmField()
            } else if let addField {
                // Retained editor (survives non-empty focus loss): keep the
                // draft but follow the row's current presentation.
                addField.font = .systemFont(ofSize: 11 * model.fontScale)
                addField.textColor = primary
                addField.caretColor = primary
            }
        } else {
            teardownField()
        }
        lastArmToken = armToken
        lastArmWorkspaceId = workspaceId
        needsLayout = true
    }

    /// Reuse teardown: drop the editor and every workspace-bound closure so
    /// a hidden pooled row stops retaining its previous workspace.
    func resetForReuse() {
        guard onCommit != nil || onCancel != nil || addField != nil else { return }
        // Ordering: disarm FIRST so the teardown-triggered focus-loss commit
        // cannot re-arm mid-reset.
        isAdding = false
        teardownField()
        onCommit = nil
        onCancel = nil
        model = nil
        lastArmToken = 0
        lastArmWorkspaceId = nil
    }

    /// Creates a fresh, empty, focus-grabbing add field (legacy bumps the
    /// field's view identity on every arm/commit for the same effect).
    func rearmField() {
        guard let model else { return }
        addField?.removeFromSuperview()
        let field = SidebarRowChecklistFocusField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 11 * model.fontScale)
        field.textColor = primary
        field.caretColor = primary
        field.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        field.setAccessibilityLabel(field.placeholderString ?? "")
        field.setAccessibilityIdentifier("SidebarChecklistAddItemField")
        // Capture the closure VALUES at field-creation time: this pooled
        // row's stored onCommit/onCancel are replaced when the cell is
        // reused for another workspace, and the OLD editor's
        // teardown-triggered focus-loss commit must go to the workspace
        // that armed it (the stored closures are workspace-bound and free
        // of section-state dereferences).
        guard let commit = onCommit, let cancel = onCancel else { return }
        let bridge = SidebarRowChecklistFieldBridge(
            onCommit: { text in
                commit(text)
            },
            onCancel: {
                cancel()
            }
        )
        // Legacy `commitInlineAdd`: an ENTER commit re-arms a fresh, focused,
        // empty add field. Focus-loss commits (teardown, replacement) never
        // re-arm — a synchronous re-arm inside removeFromSuperview would
        // strand an untracked editor.
        bridge.onReturnCommit = { [weak self] in
            self?.rearmFieldIfStillAdding()
        }
        // A focus-loss commit keeps the field armed (legacy parity) but must
        // not keep the submitted draft — a later Return would add it twice.
        bridge.onEndEditingCommit = { [weak field] in
            field?.stringValue = ""
        }
        field.delegate = bridge
        addFieldBridge = bridge
        addField = field
        // Valid frame BEFORE the window attach: the focus grab installs the
        // field editor immediately, and an editor set up against a zero
        // frame draws an oversized dark box over the row.
        field.frame = plannedFieldFrame()
        addSubview(field)
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(field)
        needsLayout = true
    }

    private func plannedFieldFrame() -> NSRect {
        guard let model else { return NSRect(x: 0, y: 0, width: 100, height: 17) }
        let iconWidth = plusIconView.image?.size.width ?? 0
        let fieldHeight = 11 * model.fontScale + 4
        let fieldX = iconWidth + 4
        return NSRect(
            x: fieldX, y: max(0, (bounds.height - fieldHeight) / 2),
            width: max(10, bounds.width - fieldX), height: fieldHeight
        )
    }

    private func rearmFieldIfStillAdding() {
        guard isAdding else { return }
        rearmField()
    }

    private func teardownField() {
        addField?.removeFromSuperview()
        addField = nil
        addFieldBridge = nil
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        if isAdding {
            let iconHeight = plusIconView.image?.size.height ?? 0
            return ceil(max(11 * model.fontScale + 4, iconHeight))
        }
        return ghostButton.measuredHeight()
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        if isAdding, let addField {
            let iconSize = plusIconView.image?.size ?? .zero
            plusIconView.frame = NSRect(
                x: 0, y: (bounds.height - iconSize.height) / 2,
                width: iconSize.width, height: iconSize.height
            )
            let fieldHeight = 11 * model.fontScale + 4
            let fieldX = iconSize.width + 4
            addField.frame = NSRect(
                x: fieldX, y: (bounds.height - fieldHeight) / 2,
                width: max(10, bounds.width - fieldX), height: fieldHeight
            )
        } else {
            ghostButton.frame = NSRect(
                x: 0, y: 0,
                width: min(ghostButton.measuredWidth(), bounds.width),
                height: bounds.height
            )
        }
    }
}

/// The ghost "+ Add item" button (icon + label, single click target).
@MainActor
final class SidebarRowChecklistGhostAddButton: NSControl {
    private let iconView = NSImageView()
    private let label = SidebarRowTextView(lines: 1)
    private var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarChecklistAddItemRow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        iconPointSize: CGFloat,
        title: String,
        font: NSFont,
        color: NSColor,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus", pointSize: iconPointSize, weight: nil
        )
        iconView.contentTintColor = color
        label.stringValue = title
        label.font = font
        label.textColor = color
        needsLayout = true
    }

    func measuredWidth() -> CGFloat {
        let iconWidth = iconView.image?.size.width ?? 0
        return ceil(iconWidth + 4 + label.sidebarNaturalCellSize.width)
    }

    func measuredHeight() -> CGFloat {
        let iconHeight = iconView.image?.size.height ?? 0
        return ceil(max(iconHeight, label.sidebarNaturalCellSize.height))
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        let labelSize = label.sidebarNaturalCellSize
        label.frame = NSRect(
            x: iconSize.width + 4, y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - iconSize.width - 4), height: labelSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire; dim while
        // pressed like the SwiftUI plain Button this ports.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

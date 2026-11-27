import AppKit
import CmuxWorkspaces
import SwiftUI

// MARK: - Attachment menu button

/// The always-visible paperclip (+ count) that manages a checklist item's
/// image attachments through a menu: Attach Images…, then per-attachment
/// Open / Remove Attachment submenus.
@MainActor
final class SidebarRowChecklistAttachmentButton: NSControl {
    private let iconView = NSImageView()
    private let countLabel = SidebarRowTextView(lines: 1)
    /// The borderless-menu disclosure chevron SwiftUI's
    /// `.menuStyle(.borderlessButton)` renders after the label.
    private let chevronView = NSImageView()
    private var item: WorkspaceChecklistItem?
    private var actions: SidebarAppKitRowActions?
    private var iconPointSize: CGFloat = 9

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        countLabel.isHidden = true
        addSubview(countLabel)
        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("WorkspaceChecklistAttachmentMenu")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func resetForReuse() {
        item = nil
        actions = nil
    }

    func configure(
        item: WorkspaceChecklistItem,
        model: SidebarWorkspaceRowModel,
        color: NSColor,
        actions: SidebarAppKitRowActions
    ) {
        self.item = item
        self.actions = actions
        // Legacy passes `iconPointSize: 9 * fontScale` (no magnification).
        iconPointSize = 9 * model.fontScale
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paperclip", pointSize: iconPointSize, weight: nil
        )
        iconView.contentTintColor = color
        chevronView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "chevron.down", pointSize: iconPointSize * 0.65, weight: .semibold
        )
        chevronView.contentTintColor = color
        countLabel.isHidden = item.attachmentCount == 0
        if item.attachmentCount > 0 {
            countLabel.stringValue = "\(item.attachmentCount)"
            countLabel.font = .monospacedDigitSystemFont(ofSize: model.scaled(10), weight: .regular)
            countLabel.textColor = color
        }
        toolTip = String(localized: "sidebar.checklist.attachmentsTooltip", defaultValue: "Manage images")
        setAccessibilityLabel(accessibilityText(count: item.attachmentCount))
        needsLayout = true
    }

    private func accessibilityText(count: Int) -> String {
        switch count {
        case 0:
            return String(
                localized: "sidebar.checklist.attachments.noneAccessibility",
                defaultValue: "No images attached. Attach images."
            )
        case 1:
            return String(localized: "sidebar.checklist.attachments.one", defaultValue: "1 image attached")
        default:
            return String.localizedStringWithFormat(
                String(
                    localized: "sidebar.checklist.attachments.other",
                    defaultValue: "%lld images attached"
                ),
                Int64(count)
            )
        }
    }

    /// Legacy footprint: the borderless-menu chevron packs INSIDE the
    /// `minWidth = iconPointSize + 8` slot next to the paperclip, so the
    /// whole control stays ~17pt wide and item text wraps at the same
    /// width as the SwiftUI row.
    func measuredSize() -> NSSize {
        let iconSize = iconView.image?.size ?? .zero
        let chevronSize = chevronView.image?.size ?? .zero
        var width = iconSize.width + (chevronSize.width > 0 ? chevronSize.width + 2 : 0)
        var height = max(iconSize.height, chevronSize.height)
        if !countLabel.isHidden {
            let countSize = countLabel.sidebarNaturalCellSize
            width += 2 + ceil(countSize.width)
            // The count uses the magnified item font, which can exceed the
            // un-magnified icon slot at large accessibility magnifications.
            height = max(height, ceil(countSize.height))
        }
        return NSSize(
            width: max(width, iconPointSize + 8),
            height: max(height, iconPointSize + 8)
        )
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.image?.size ?? .zero
        let countSize = countLabel.isHidden ? NSSize.zero : countLabel.sidebarNaturalCellSize
        let chevronSize = chevronView.image?.size ?? .zero
        let labelWidth = iconSize.width + (countLabel.isHidden ? 0 : 2 + ceil(countSize.width))
        let contentWidth = labelWidth + (chevronSize.width > 0 ? chevronSize.width + 2 : 0)
        var x = (bounds.width - contentWidth) / 2
        iconView.frame = NSRect(
            x: x, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        x += iconSize.width + 2
        if !countLabel.isHidden {
            countLabel.frame = NSRect(
                x: x, y: (bounds.height - countSize.height) / 2,
                width: ceil(countSize.width), height: countSize.height
            )
            x += ceil(countSize.width) + 2
        }
        chevronView.frame = NSRect(
            x: x, y: (bounds.height - chevronSize.height) / 2,
            width: chevronSize.width, height: chevronSize.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        presentAttachmentsMenu()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Menu.
    override func accessibilityPerformPress() -> Bool {
        guard item != nil, actions != nil else { return false }
        presentAttachmentsMenu()
        return true
    }

    private func presentAttachmentsMenu() {
        guard let item, let actions else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarRowClosureMenuItem(
            title: String(localized: "sidebar.checklist.attachImages", defaultValue: "Attach Images…")
        ) { [actions] in
            actions.checklistAddAttachments(item.id)
        })
        if !item.attachments.isEmpty {
            menu.addItem(.separator())
            for attachment in item.attachments {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                submenu.addItem(SidebarRowClosureMenuItem(
                    title: String(localized: "sidebar.checklist.openAttachment", defaultValue: "Open")
                ) { [actions] in
                    actions.checklistOpenAttachments(item.id, attachment.id)
                })
                submenu.addItem(SidebarRowClosureMenuItem(
                    title: String(
                        localized: "sidebar.checklist.removeAttachment",
                        defaultValue: "Remove Attachment"
                    )
                ) { [actions] in
                    actions.checklistRemoveAttachment(item.id, attachment.id)
                })
                let parent = NSMenuItem(title: attachment.displayName, action: nil, keyEquivalent: "")
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

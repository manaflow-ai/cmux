import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Pure-AppKit group header cell for the sidebar workspace table.
///
/// Renders the collapsible group header (pin, chevron, name, unread badge,
/// hover-revealed plus button) without any SwiftUI
/// hosting so scroll, hover, and reconfigure stay off the AttributeGraph.
/// Layout is manual: subviews are created once and framed in `layout()`.
@MainActor
final class SidebarGroupHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarGroupHeaderTableCellView")
    private static let backgroundCornerRadius: CGFloat = 10
    private static let hoverBackgroundOpacity: CGFloat = 0.08

    private let backgroundView = NSView()
    private let pinImageView = NSImageView()
    private let chevronButton = SidebarHeaderGlyphButton()
    private let nameField = NSTextField(labelWithString: "")
    // Direct-draw badge shared with workspace rows, avoiding NSTextField's
    // asymmetric cell insets for small counts.
    private let unreadBadgeView = SidebarRowUnreadBadgeView()
    private var unreadBadgeFont: NSFont = .systemFont(ofSize: 10, weight: .regular)
    private let plusButton = SidebarHeaderGlyphButton()
    private let topDropIndicator = NSView()
    private let bottomDropIndicator = NSView()
    private let hintPill = SidebarShortcutHintPillView()

    private var model: SidebarGroupHeaderRowModel?
    private var actions: SidebarGroupHeaderRowActions?
    private var isPointerHovering = false
    private var contextMenuVisible = false
    private var contextMenuDidOpen: (() -> Void)?
    private var contextMenuDidClose: (() -> Void)?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Manual layout: the table resizes recycled cells after configure, so
        // a size change must always re-run layout() or slots keep the widths
        // they had at make time.
        if changed {
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        // Drop indicators paint into the inter-row gap above/below the cell.
        layer?.masksToBounds = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Self.backgroundCornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        addSubview(backgroundView)

        pinImageView.imageScaling = .scaleProportionallyDown
        addSubview(pinImageView)

        chevronButton.onClick = { [weak self] in self?.actions?.onToggleCollapsed() }
        addSubview(chevronButton)

        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.setAccessibilityIdentifier("SidebarWorkspaceGroupName")
        addSubview(nameField)

        addSubview(unreadBadgeView)

        plusButton.onClick = { [weak self] in self?.actions?.onTapPlus() }
        plusButton.menuProvider = { [weak self] in self?.makePlusMenu() }
        addSubview(plusButton)

        topDropIndicator.wantsLayer = true
        bottomDropIndicator.wantsLayer = true
        addSubview(topDropIndicator)
        addSubview(bottomDropIndicator)

        addSubview(hintPill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        suspendPresentation()
        model = nil
        hintPill.resetForReuse()
    }

    func suspendPresentation() {
        actions = nil
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        contextMenuVisible = false
    }

    func configurePresentation(model: SidebarGroupHeaderRowModel) {
        suspendPresentation()
        guard self.model != model else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    // MARK: Configure

    func configure(
        model: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        let requiresFullApply = self.actions == nil
        let previous = self.model
        self.actions = actions
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        let hoverChanged = self.isPointerHovering != isPointerHovering
        self.isPointerHovering = isPointerHovering
        guard requiresFullApply || previous != model || hoverChanged else { return }
        self.model = model
        applyModel(model)
        needsLayout = true
    }

    private func applyModel(_ model: SidebarGroupHeaderRowModel) {
        // Legacy parity: no implicit layer actions on content/color changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent

        pinImageView.isHidden = !model.isPinned
        if model.isPinned {
            pinImageView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "pin.fill",
                pointSize: GlobalFontMagnification.scaledSize(metrics.pinnedIconFontSize, percent: percent),
                weight: .semibold
            )
            pinImageView.contentTintColor = .secondaryLabelColor
            pinImageView.toolTip = String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
        }

        chevronButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: model.isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: GlobalFontMagnification.scaledSize(metrics.chevronFontSize, percent: percent),
            weight: .semibold
        )
        chevronButton.contentTintColor = .secondaryLabelColor
        chevronButton.setAccessibilityLabel(
            model.isCollapsed
                ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        )

        let nameFont = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .regular
        )
        let nameColor = NSColor.labelColor
        if let rendered = SidebarMarkdownRenderer(markdown: model.name).inline {
            nameField.attributedStringValue = SidebarRowPalette.attributed(
                rendered,
                font: nameFont,
                color: nameColor
            )
        } else {
            nameField.stringValue = model.name
            nameField.font = nameFont
            nameField.textColor = nameColor
        }

        let showsBadge = model.anchorUnreadCount > 0
        unreadBadgeView.isHidden = !showsBadge
        if showsBadge {
            unreadBadgeFont = .systemFont(
                ofSize: GlobalFontMagnification.scaledSize(metrics.unreadFontSize, percent: percent),
                weight: .regular
            )
            unreadBadgeView.configure(
                count: model.anchorUnreadCount,
                fillColor: .controlAccentColor,
                textColor: .white,
                font: unreadBadgeFont
            )
            unreadBadgeView.setAccessibilityLabel(
                SidebarRowUnreadBadgeView.accessibilityLabel(
                    forUnreadCount: model.anchorUnreadCount
                )
            )
        }

        plusButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "plus",
            pointSize: GlobalFontMagnification.scaledSize(metrics.plusFontSize, percent: percent),
            weight: .medium
        )
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.setAccessibilityLabel(String(
            localized: "workspaceGroup.newWorkspaceInGroup.a11y",
            defaultValue: "New workspace in group"
        ))

        backgroundView.layer?.cornerRadius = Self.backgroundCornerRadius
        backgroundView.layer?.backgroundColor = headerBackgroundColor(for: model).cgColor

        topDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        bottomDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible

        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: GlobalFontMagnification.scaledSize(9, percent: percent),
            emphasis: model.isAnchorActive ? 1.0 : 0.9,
            representedIdentity: model.groupId
        )

        alphaValue = model.isBeingDragged ? 0.6 : 1
        updatePlusVisibility()
        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(model.groupId.uuidString)")
        setAccessibilityLabel(nameField.stringValue)
    }

    /// Live drop-line painting during native reorder drags; see
    /// `SidebarWorkspaceRowTableCellView.paintControllerDropIndicator`.
    func paintControllerDropIndicator(top: Bool, bottom: Bool) {
        topDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        bottomDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        topDropIndicator.isHidden = !top
        bottomDropIndicator.isHidden = !bottom
    }

#if DEBUG
    var dropIndicatorPaintForTesting: (top: Bool, bottom: Bool) {
        (!topDropIndicator.isHidden, !bottomDropIndicator.isHidden)
    }
#endif

    private func updatePlusVisibility() {
        let showsHint = model?.shortcutHintText != nil
        plusButton.setRevealed(isPointerHovering && !contextMenuVisible && !showsHint)
    }

    /// Authoritative hover enforcement: the controller sweeps visible cells
    /// so hover-revealed chrome cannot strand on rows the pointer left
    /// (row-index/id races during churn made per-transition repaints miss).
    func enforcePointerHovering(_ hovering: Bool) {
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
        if let model {
            applyModel(model)
        } else {
            updatePlusVisibility()
        }
    }

    /// Optimistic press treatment: paints the anchor-active header visuals
    /// instantly (group clicks focus the anchor workspace); the next
    /// authoritative configure reconciles.
    func showOptimisticAnchorActive() {
        guard let model, !model.isAnchorActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = Self.backgroundCornerRadius
        backgroundView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        CATransaction.commit()
        recolorName(.labelColor)
    }

    /// Modifier-click preview: paints the same dim membership tint as an
    /// unfocused multi-selected workspace row.
    func showOptimisticMultiSelection() {
        guard let model, !model.isAnchorActive, !model.isMultiSelected else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = Self.backgroundCornerRadius
        backgroundView.layer?.backgroundColor = headerMultiSelectionBackgroundColor(for: model).cgColor
        CATransaction.commit()
    }

    /// Plain-click counterpart: clears active and multi-selected header paint
    /// while the authoritative single selection is applied.
    func showOptimisticDeselection() {
        guard let model, model.isAnchorActive || model.isMultiSelected else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = Self.backgroundCornerRadius
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
        recolorName(.labelColor)
    }

    /// Inverse of the press treatment: previewing a different row must peel a
    /// pending header's optimistic anchor-active visuals. The authoritative
    /// apply reconfigures only rows whose model changed, and a replaced
    /// preview never changes this header's model — without an explicit clear
    /// the painted treatment would linger indefinitely.
    func clearOptimisticAnchorActive() {
        guard let model, !model.isAnchorActive else { return }
        applyModel(model)
    }

    private func recolorName(_ color: NSColor) {
        let mutable = NSMutableAttributedString(attributedString: nameField.attributedStringValue)
        mutable.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: mutable.length)
        )
        nameField.attributedStringValue = mutable
    }

    private func headerBackgroundColor(for model: SidebarGroupHeaderRowModel) -> NSColor {
        if model.isAnchorActive {
            let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .dark
                : .light
            return sidebarSelectedWorkspaceBackgroundNSColor(for: scheme)
        }
        if model.isMultiSelected {
            return headerMultiSelectionBackgroundColor(for: model)
        }
        if isPointerHovering {
            return NSColor.labelColor.withAlphaComponent(Self.hoverBackgroundOpacity)
        }
        return .clear
    }

    private func headerMultiSelectionBackgroundColor(
        for model: SidebarGroupHeaderRowModel
    ) -> NSColor {
        let style = model.multiSelectionBackgroundStyle
        guard let color = style.color else { return .clear }
        return color.withAlphaComponent(
            color.alphaComponent * style.opacity
        )
    }

    /// True when a press at this view should not repaint selection (chevron
    /// toggles collapse, plus creates a workspace — neither selects).
    func selectionPreviewShouldIgnore(_ hitView: NSView) -> Bool {
        hitView === chevronButton || hitView.isDescendant(of: chevronButton)
            || hitView === plusButton || hitView.isDescendant(of: plusButton)
    }

    // MARK: Layout

    /// Deterministic row height; must stay in lockstep with `layout()`.
    static func preferredHeight(model: SidebarGroupHeaderRowModel) -> CGFloat {
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent
        let nameFont = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .regular
        )
        let nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        let content = max(metrics.chevronFrame, metrics.plusFrame, nameLineHeight)
        return ceil(content + 10)
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        // No implicit actions during manual layout (legacy parity —
        // geometry snaps, never interpolates).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)
        let percent = model.globalFontMagnificationPercent
        let outerPad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let bgFrame = NSRect(x: outerPad, y: 0, width: bounds.width - outerPad * 2, height: bounds.height)
        backgroundView.frame = bgFrame
        let contentMaxX = bgFrame.maxX - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let midY = bounds.height / 2
        var x = bgFrame.minX + SidebarWorkspaceListMetrics.rowContentHorizontalPadding

        func centered(_ size: CGFloat) -> NSRect {
            NSRect(x: x, y: midY - size / 2, width: size, height: size)
        }

        if !pinImageView.isHidden {
            pinImageView.frame = centered(metrics.pinFrame)
            x = pinImageView.frame.maxX + 4
        }
        chevronButton.frame = centered(metrics.chevronFrame)
        x = chevronButton.frame.maxX + 4

        var badgeSize = NSSize.zero
        if !unreadBadgeView.isHidden {
            badgeSize = unreadBadgeView.fittingSize(
                horizontalPadding: metrics.unreadHorizontalPadding,
                minimumHeight: GlobalFontMagnification.scaledSize(
                    14 * model.fontScale,
                    percent: percent
                )
            )
        }

        let badgeSpacing: CGFloat = 6
        let badgeOnLeading = !unreadBadgeView.isHidden && model.notificationBadgePosition == .leading
        let badgeOnTrailing = !unreadBadgeView.isHidden && model.notificationBadgePosition == .trailing
        var trailingAccessoryMaxX = contentMaxX
        if badgeOnTrailing {
            unreadBadgeView.frame = NSRect(
                x: contentMaxX - badgeSize.width,
                y: midY - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            )
            unreadBadgeView.needsDisplay = true
            trailingAccessoryMaxX = unreadBadgeView.frame.minX - badgeSpacing
        }

        let plusSide = metrics.plusFrame
        plusButton.frame = NSRect(
            x: trailingAccessoryMaxX - plusSide,
            y: midY - plusSide / 2,
            width: plusSide,
            height: plusSide
        )

        let accessoryGap: CGFloat = 4
        let nameAndLeadingBadgeMaxX = plusButton.frame.minX - accessoryGap
        let nameSize = nameField.attributedStringValue.size()
        let nameAvailable = badgeOnLeading
            ? max(0, nameAndLeadingBadgeMaxX - x - badgeSpacing - badgeSize.width)
            : max(0, nameAndLeadingBadgeMaxX - x)
        let nameWidth = badgeOnLeading ? min(nameSize.width, nameAvailable) : nameAvailable
        // The field owns all space before the fixed trailing accessories.
        nameField.frame = NSRect(
            x: x,
            y: midY - ceil(nameSize.height) / 2,
            width: nameWidth,
            height: ceil(nameSize.height)
        )
        if badgeOnLeading {
            unreadBadgeView.frame = NSRect(
                x: nameField.frame.maxX + badgeSpacing,
                y: midY - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            )
            unreadBadgeView.needsDisplay = true
        }

        let indicatorX: CGFloat = 8
        let indicatorWidth = max(0, bounds.width - indicatorX - 8)
        let topOffset: CGFloat = model.isFirstRow ? 0 : -(model.rowSpacing / 2)
        topDropIndicator.frame = NSRect(x: indicatorX, y: topOffset, width: indicatorWidth, height: 2)
        let bottomInset = metrics.groupScopedBottomDropIndicatorLeadingInset
        bottomDropIndicator.frame = NSRect(
            x: 8 + bottomInset,
            y: bounds.height - 2 + model.rowSpacing / 2,
            width: max(0, bounds.width - (8 + bottomInset) - 8),
            height: 2
        )

        let pillSize = hintPill.fittingPillSize()
        let pillMaxX = unreadBadgeView.isHidden
            ? bounds.width - 10
            : unreadBadgeView.frame.minX - badgeSpacing
        hintPill.frame = NSRect(
            x: pillMaxX - pillSize.width + ShortcutHintDebugSettings.clamped(model.shortcutHintXOffset),
            y: 6 + ShortcutHintDebugSettings.clamped(model.shortcutHintYOffset),
            width: pillSize.width,
            height: pillSize.height
        )
    }

    // MARK: Interaction

    // Selection has exactly one click owner: the table view's action
    // (`SidebarWorkspaceTableController.didClickTableRow`), same as workspace
    // rows. A cell-level click recognizer here would fire a second
    // `onFocusAnchor` for the same click, which cancels a modifier-click
    // toggle (add then remove) and made header multi-selection impossible.

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if plusButton.frame.contains(point), !plusButton.isHidden {
            return makePlusMenu()
        }
        return makeHeaderMenu()
    }

    // MARK: Menus

    private func menuItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = MenuAction(run: action)
        return item
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    private func trackedMenu() -> NSMenu {
        let menu = SidebarRowTrackedMenu()
        menu.autoenablesItems = false
        // Keep the matching close callback alive if this row retires while
        // AppKit is still tracking its menu.
        let didOpen = contextMenuDidOpen
        let didClose = contextMenuDidClose
        menu.onOpen = { [weak self] in
            self?.contextMenuVisible = true
            self?.updatePlusVisibility()
            didOpen?()
        }
        menu.onClose = { [weak self] in
            self?.contextMenuVisible = false
            self?.updatePlusVisibility()
            didClose?()
        }
        menu.delegate = menu
        return menu
    }

    private func makePlusMenu() -> NSMenu {
        guard let actions else { return NSMenu() }
        let menu = trackedMenu()
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.newWorkspace", defaultValue: "New Workspace in Group"),
            action: actions.onTapPlus
        ))
        appendResolvedConfigItems(to: menu)
        menu.addItem(.separator())
        appendConfigAndDocsItems(to: menu)
        return menu
    }

    private func appendResolvedConfigItems(to menu: NSMenu) {
        guard let model, let actions, !model.cwdContextMenuItems.isEmpty else { return }
        menu.addItem(.separator())
        for item in model.cwdContextMenuItems {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                menu.addItem(menuItem(action.title) { actions.onRunResolvedItem(action) })
            }
        }
    }

    private func appendConfigAndDocsItems(to menu: NSMenu) {
        guard let actions else { return }
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.editConfig", defaultValue: "Edit Group Config..."),
            action: actions.onEditConfig
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.openDocs", defaultValue: "Open Workspace Groups Docs"),
            action: actions.onOpenDocs
        ))
    }

    private func makeHeaderMenu() -> NSMenu {
        guard let model, let actions else { return NSMenu() }
        let menu = trackedMenu()
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.plus.contextMenu.newWorkspace", defaultValue: "New Workspace in Group"),
            action: actions.onTapPlus
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.rename", defaultValue: "Rename Group..."),
            action: actions.onRename
        ))
        menu.addItem(menuItem(
            model.isPinned
                ? String(localized: "workspaceGroup.contextMenu.unpin", defaultValue: "Unpin Group")
                : String(localized: "workspaceGroup.contextMenu.pin", defaultValue: "Pin Group"),
            action: actions.onTogglePinned
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markRead", defaultValue: "Mark Group as Read"),
            enabled: model.canMarkRead,
            action: actions.onMarkRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markUnread", defaultValue: "Mark Group as Unread"),
            enabled: model.canMarkUnread,
            action: actions.onMarkUnread
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            enabled: model.hasLatestNotifications,
            action: actions.onClearLatestNotifications
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllRead", defaultValue: "Mark All Workspaces in Group as Read"),
            enabled: model.canMarkAllRead,
            action: actions.onMarkAllRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllUnread", defaultValue: "Mark All Workspaces in Group as Unread"),
            enabled: model.canMarkAllUnread,
            action: actions.onMarkAllUnread
        ))
        menu.addItem(.separator())
        appendConfigAndDocsItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.ungroup", defaultValue: "Ungroup Workspaces"),
            action: actions.onUngroup
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.delete", defaultValue: "Delete Group"),
            action: actions.onDelete
        ))
        return menu
    }
}

/// Borderless glyph button used for the header chevron and plus controls.
@MainActor
final class SidebarHeaderGlyphButton: NSButton {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    var glyphImage: NSImage? {
        didSet { image = glyphImage }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        target = self
        action = #selector(didClick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didClick() {
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    /// Arc-style hover reveal: 120ms ease-out fade instead of a hard snap.
    /// Hit-testing follows the target state immediately so a fading-out
    /// button never swallows a click.
    func setRevealed(_ revealed: Bool) {
        if revealed {
            if isHidden {
                alphaValue = 0
                isHidden = false
            }
            isEnabled = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            guard !isHidden else { return }
            isEnabled = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isEnabled else { return }
                self.isHidden = true
            })
        }
    }
}

/// AppKit rendition of the sidebar shortcut-hint capsule. The outer view owns
/// the shadow while the inner visual-effect view clips material to the capsule;
/// putting both on one unclipped layer leaves a square material background.
@MainActor
final class SidebarShortcutHintPillView: NSView {
    private static let horizontalPadding: CGFloat = 4
    private static let visibilityAnimationKey = "shortcutHintVisibility"

    private let materialView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let reduceMotionProvider: () -> Bool
    private var emphasis: Double = 1.0
    private var representedIdentity: UUID?
    private var isRevealed = false
    private var visibilityGeneration: UInt64 = 0

    init(
        reduceMotionProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.reduceMotionProvider = reduceMotionProvider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        materialView.material = .popover
        materialView.state = .active
        materialView.blendingMode = .withinWindow
        materialView.wantsLayer = true
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.8
        addSubview(materialView)

        label.alignment = .center
        label.lineBreakMode = .byClipping
        materialView.addSubview(label)
        layer?.opacity = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String?,
        fontSize: CGFloat,
        emphasis: Double,
        representedIdentity: UUID? = nil
    ) {
        let identityChanged = self.representedIdentity != representedIdentity
        self.representedIdentity = representedIdentity
        guard let text else {
            setRevealed(false, animated: !identityChanged)
            return
        }
        self.emphasis = emphasis
        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .labelColor
        materialView.layer?.borderColor = NSColor.white.withAlphaComponent(0.30 * emphasis).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.22 * emphasis).cgColor
        setRevealed(true, animated: !identityChanged)
    }

    func fittingPillSize() -> NSSize {
        guard !isHidden else { return .zero }
        let textSize = label.sidebarNaturalCellSize
        return NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: ceil(textSize.height) + 4
        )
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        materialView.frame = bounds
        materialView.layer?.cornerRadius = radius
        label.frame = materialView.bounds.insetBy(dx: Self.horizontalPadding, dy: 2)
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func resetForReuse() {
        representedIdentity = nil
        isRevealed = false
        visibilityGeneration &+= 1
        applyImmediateVisibility(false)
        label.stringValue = ""
    }

    private func setRevealed(_ revealed: Bool, animated: Bool = true) {
        if !animated {
            isRevealed = revealed
            visibilityGeneration &+= 1
            applyImmediateVisibility(revealed)
            return
        }
        guard isRevealed != revealed else { return }
        isRevealed = revealed
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        if reduceMotionProvider() {
            applyImmediateVisibility(revealed)
            return
        }

        if revealed {
            if isHidden {
                layer?.opacity = 0
                isHidden = false
            }
            animateOpacity(to: 1, generation: generation)
        } else {
            guard !isHidden else {
                layer?.opacity = 0
                return
            }
            animateOpacity(to: 0, generation: generation, hidesWhenFinished: true)
        }
    }

    private func applyImmediateVisibility(_ revealed: Bool) {
        layer?.removeAnimation(forKey: Self.visibilityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = revealed ? 1 : 0
        CATransaction.commit()
        isHidden = !revealed
    }

    private func animateOpacity(
        to value: Float,
        generation: UInt64,
        hidesWhenFinished: Bool = false
    ) {
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = value
        animation.duration = ShortcutHintAnimation.visibilityDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hidesWhenFinished {
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.visibilityGeneration == generation,
                          !self.isRevealed else { return }
                    self.isHidden = true
                }
            }
        }
        layer.opacity = value
        layer.add(animation, forKey: Self.visibilityAnimationKey)
        CATransaction.commit()
    }
}

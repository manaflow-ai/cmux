import AppKit
import CmuxFoundation
import SwiftUI

/// Pure-AppKit group header cell for the sidebar workspace table.
///
/// Renders the collapsible group/folder header (pin, chevron, tinted icon,
/// name, unread capsule, hover-revealed plus button) without any SwiftUI
/// hosting so scroll, hover, and reconfigure stay off the AttributeGraph.
/// Layout is manual: subviews are created once and framed in `layout()`.
@MainActor
final class SidebarGroupHeaderTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarGroupHeaderTableCellView")

    private let backgroundView = NSView()
    private let pinImageView = NSImageView()
    private let chevronButton = SidebarHeaderGlyphButton()
    private let iconImageView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    // Direct-draw badge (shared with workspace rows): NSTextField's
    // intrinsic insets shift single digits off the circle's optical center.
    private let unreadBadgeView = SidebarRowUnreadBadgeView()
    private var unreadBadgeFont: NSFont = .systemFont(ofSize: 10, weight: .semibold)
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
        backgroundView.layer?.cornerRadius = 4
        backgroundView.layer?.cornerCurve = .continuous
        addSubview(backgroundView)

        pinImageView.imageScaling = .scaleProportionallyDown
        pinImageView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        addSubview(pinImageView)

        chevronButton.onClick = { [weak self] in self?.actions?.onToggleCollapsed() }
        addSubview(chevronButton)

        iconImageView.imageScaling = .scaleProportionallyDown
        addSubview(iconImageView)

        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
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
        installFocusClickRecognizer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Configure

    func configure(
        model: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        let previous = self.model
        self.actions = actions
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        let hoverChanged = self.isPointerHovering != isPointerHovering
        self.isPointerHovering = isPointerHovering
        guard previous != model || hoverChanged else { return }
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

        let iconSymbol = RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: model.iconSymbol, configured: nil)
        iconImageView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: iconSymbol,
            pointSize: GlobalFontMagnification.scaledSize(metrics.iconFontSize, percent: percent),
            weight: .semibold
        )
        iconImageView.contentTintColor = model.tintHex.flatMap { NSColor(hex: $0) } ?? .secondaryLabelColor

        nameField.stringValue = model.name
        nameField.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .semibold
        )
        nameField.textColor = model.isAnchorActive ? .labelColor : NSColor.labelColor.withAlphaComponent(0.9)

        let showsBadge = model.anchorUnreadCount > 0
        unreadBadgeView.isHidden = !showsBadge
        if showsBadge {
            unreadBadgeFont = .systemFont(
                ofSize: GlobalFontMagnification.scaledSize(metrics.unreadFontSize, percent: percent),
                weight: .semibold
            )
            unreadBadgeView.configure(
                count: model.anchorUnreadCount,
                fillColor: .controlAccentColor,
                textColor: .white,
                font: unreadBadgeFont
            )
            unreadBadgeView.setAccessibilityLabel(String.localizedStringWithFormat(
                String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                model.anchorUnreadCount
            ))
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

        backgroundView.layer?.backgroundColor = model.isAnchorActive
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor

        topDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        bottomDropIndicator.layer?.backgroundColor = cmuxAccentNSColor().cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible

        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: GlobalFontMagnification.scaledSize(10, percent: percent),
            emphasis: model.isAnchorActive ? 1.0 : 0.9
        )

        alphaValue = model.isBeingDragged ? 0.6 : 1
        updatePlusVisibility()
        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(model.groupId.uuidString)")
        setAccessibilityLabel(model.name)
    }

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
        updatePlusVisibility()
    }

    /// Optimistic press treatment: paints the anchor-active header visuals
    /// instantly (group clicks focus the anchor workspace); the next
    /// authoritative configure reconciles.
    func showOptimisticAnchorActive() {
        guard let model, !model.isAnchorActive else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        CATransaction.commit()
        nameField.textColor = .labelColor
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
            weight: .semibold
        )
        let nameLineHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        let content = max(metrics.chevronFrame, metrics.iconFrame, metrics.plusFrame, nameLineHeight)
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
        let outerPad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let bgFrame = NSRect(x: outerPad, y: 0, width: bounds.width - outerPad * 2, height: bounds.height)
        backgroundView.frame = bgFrame
        let contentMaxX = bgFrame.maxX - SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let midY = bounds.height / 2
        var x = bgFrame.minX

        func centered(_ size: CGFloat) -> NSRect {
            NSRect(x: x, y: midY - size / 2, width: size, height: size)
        }

        if !pinImageView.isHidden {
            pinImageView.frame = centered(metrics.iconFrame)
            x = pinImageView.frame.maxX + 4
        }
        chevronButton.frame = centered(metrics.chevronFrame)
        x = chevronButton.frame.maxX + 4

        let plusSide = metrics.plusFrame
        plusButton.frame = NSRect(x: contentMaxX - plusSide, y: midY - plusSide / 2, width: plusSide, height: plusSide)

        iconImageView.frame = centered(metrics.iconFrame)
        x = iconImageView.frame.maxX + 6

        var badgeSize = NSSize.zero
        if !unreadBadgeView.isHidden {
            let textSize = NSString(string: "\(model.anchorUnreadCount)")
                .size(withAttributes: [.font: unreadBadgeFont])
            badgeSize = NSSize(
                width: ceil(textSize.width) + metrics.unreadHorizontalPadding * 2,
                height: ceil(textSize.height) + metrics.unreadVerticalPadding * 2
            )
        }

        let nameAvailable = max(0, (plusButton.frame.minX - 4) - x
            - (badgeSize.width > 0 ? badgeSize.width + 6 : 0))
        let nameSize = nameField.attributedStringValue.size()
        // The field owns ALL remaining width (truncation only when genuinely
        // out of space); the badge tracks the measured text width instead.
        nameField.frame = NSRect(
            x: x,
            y: midY - ceil(nameSize.height) / 2,
            width: nameAvailable,
            height: ceil(nameSize.height)
        )
        if !unreadBadgeView.isHidden {
            let badgeX = x + min(ceil(nameSize.width), nameAvailable) + 6
            unreadBadgeView.frame = NSRect(
                x: badgeX,
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
        hintPill.frame = NSRect(
            x: bounds.width - pillSize.width - 10 + ShortcutHintDebugSettings.clamped(model.shortcutHintXOffset),
            y: 6 + ShortcutHintDebugSettings.clamped(model.shortcutHintYOffset),
            width: pillSize.width,
            height: pillSize.height
        )
    }

    // MARK: Interaction

    /// Click-to-focus is a gesture recognizer, not a mouseDown override, so
    /// the table view keeps receiving the raw mouse events it needs to start
    /// a row drag from the header's name area (parity with the SwiftUI
    /// header's coexisting onTapGesture + onDrag).
    private func installFocusClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(didClickFocusArea(_:)))
        recognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(recognizer)
    }

    @objc private func didClickFocusArea(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        // Chevron/plus are buttons and take their own hits before this runs.
        let innerRect = NSRect(
            x: iconImageView.frame.minX,
            y: 0,
            width: max(0, plusButton.frame.minX - iconImageView.frame.minX),
            height: bounds.height
        )
        if innerRect.contains(point) {
            actions?.onFocusAnchor()
        }
    }

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
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
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

extension SidebarGroupHeaderTableCellView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        contextMenuVisible = true
        updatePlusVisibility()
        contextMenuDidOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenuVisible = false
        updatePlusVisibility()
        contextMenuDidClose?()
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

/// AppKit rendition of the sidebar shortcut-hint capsule (material + stroke +
/// shadow), shown only while modifier-hold digit hints are active.
@MainActor
final class SidebarShortcutHintPillView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var emphasis: Double = 1.0

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.borderWidth = 0.8
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String?, fontSize: CGFloat, emphasis: Double) {
        guard let text else {
            isHidden = true
            return
        }
        self.emphasis = emphasis
        isHidden = false
        label.stringValue = text
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .labelColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.30 * emphasis).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.22 * emphasis).cgColor
    }

    func fittingPillSize() -> NSSize {
        guard !isHidden else { return .zero }
        let textSize = label.sidebarNaturalCellSize
        return NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 6, dy: 2)
    }
}

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

    /// Selection fill and edge layer. Internal so tests read its paint directly.
    let backgroundView = NSView()
    /// Row hover wash; see `SidebarRowHover.swift`.
    let rowHoverLayer = CALayer()
    private let pinImageView = NSImageView()
    private let chevronButton = SidebarHeaderGlyphButton()
    private let iconImageView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    // Direct-draw badge (shared with workspace rows): NSTextField's
    // intrinsic insets shift single digits off the circle's optical center.
    private let unreadBadgeView = SidebarRowUnreadBadgeView()
    private var unreadBadgeFont: NSFont = .systemFont(ofSize: 10, weight: .semibold)
    /// Compact status mode: replaces the unread badge; see `model.statusGlyph`.
    private let statusGlyphView = SidebarCompactStatusGlyphImageView()
    private let plusButton = SidebarHeaderGlyphButton()
    private let topDropIndicator = SidebarReorderIndicatorView()
    private let bottomDropIndicator = SidebarReorderIndicatorView()
    private let hintPill = SidebarShortcutHintPillView()

    private(set) var model: SidebarGroupHeaderRowModel?
    private var actions: SidebarGroupHeaderRowActions?
    /// Mirrors the table controller's flag, as workspace row cells do, so a
    /// cell configured while the sidebar is hidden does not restart the pulse.
    private var isPresentationActive = true
    var isPointerHovering = false
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
        SidebarGlassSelection.installHoverLayer(rowHoverLayer, in: backgroundView)

        pinImageView.imageScaling = .scaleProportionallyDown
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
        addSubview(statusGlyphView)

        plusButton.onClick = { [weak self] in self?.actions?.onTapPlus() }
        plusButton.menuProvider = { [weak self] in self?.makePlusMenu() }
        plusButton.concealImmediately()
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
        isPointerHovering = false
        rowHoverLayer.isHidden = true
        plusButton.concealImmediately()
        hintPill.resetForReuse()
    }

    func setPresentationActive(_ isActive: Bool) {
        isPresentationActive = isActive
        statusGlyphView.isPresentationActive = isActive
    }

    /// Stops the live presentation without forgetting what it should go back
    /// to. Only the glyph view's flag is cleared, never this cell's: `configure`
    /// reapplies the cell's stored `isPresentationActive` to the glyph view on
    /// every reconfiguration, so clearing the stored one here would leave
    /// nothing to restore it and a reused cell's pulse would never start again.
    func suspendPresentation() {
        actions = nil
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        contextMenuVisible = false
        statusGlyphView.isPresentationActive = false
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
        statusGlyphView.isPresentationActive = isPresentationActive
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
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        let colorResolver = SidebarAppearanceColorResolver()

        pinImageView.isHidden = !model.isPinned
        if model.isPinned {
            pinImageView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "pin.fill",
                pointSize: GlobalFontMagnification.scaledSize(metrics.pinnedIconFontSize, percent: percent),
                weight: .semibold
            )
            pinImageView.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
            pinImageView.toolTip = String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
        }

        chevronButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: model.isCollapsed ? "chevron.right" : "chevron.down",
            pointSize: GlobalFontMagnification.scaledSize(metrics.chevronFontSize, percent: percent),
            weight: .semibold
        )
        chevronButton.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
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
        iconImageView.contentTintColor = model.tintHex.flatMap { NSColor(hex: $0) }
            ?? colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)

        nameField.stringValue = model.name
        nameField.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(metrics.nameFontSize, percent: percent),
            weight: .semibold
        )
        nameField.textColor = model.isAnchorActive
            ? colorResolver.resolvedColor(.labelColor, for: colorScheme)
            : colorResolver.resolvedColor(.labelColor, for: colorScheme, opacity: 0.9)

        // In compact status mode unread folds into the glyph (blue), so the
        // count badge stays off even when no member state rolls up.
        statusGlyphView.isHidden = model.statusGlyph == nil
        if let glyph = model.statusGlyph {
            statusGlyphView.configure(
                glyph,
                pointSize: GlobalFontMagnification.scaledSize(metrics.iconFontSize, percent: percent),
                color: glyph.color(
                    isActive: false,
                    selected: .labelColor,
                    secondary: colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
                )
            )
        }
        let showsBadge = model.statusGlyph == nil && !model.compactsAgentStatus && model.anchorUnreadCount > 0
        unreadBadgeView.isHidden = !showsBadge
        if showsBadge {
            unreadBadgeFont = .systemFont(
                ofSize: GlobalFontMagnification.scaledSize(metrics.unreadFontSize, percent: percent),
                weight: .semibold
            )
            unreadBadgeView.configure(
                count: model.anchorUnreadCount,
                fillColor: cmuxNotificationBadgeNSColor(
                    hex: model.notificationBadgeColorHex,
                    fallback: model.accentColor.nsColor(for: colorScheme)
                ),
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
        plusButton.contentTintColor = colorResolver.resolvedColor(.secondaryLabelColor, for: colorScheme)
        plusButton.hoverFillColor = colorResolver.resolvedColor(.labelColor, for: colorScheme)
        plusButton.setAccessibilityLabel(String(
            localized: "workspaceGroup.newWorkspaceInGroup.a11y",
            defaultValue: "New workspace in group"
        ))

        backgroundView.layer?.cornerRadius = model.isMultiSelected && !model.isAnchorActive
            ? 6
            : 4
        backgroundView.layer?.backgroundColor = headerBackgroundColor(for: model).cgColor
        applySelectionEdge(headerSelectionEdgeColor(for: model))

        topDropIndicator.accentColor = model.accentColor
        bottomDropIndicator.accentColor = model.accentColor
        let accent = model.accentColor.nsColor(for: colorScheme)
        topDropIndicator.layer?.backgroundColor = accent.cgColor
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible

        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: GlobalFontMagnification.scaledSize(9, percent: percent),
            emphasis: model.isAnchorActive ? 1.0 : 0.9,
            colorScheme: colorScheme,
            representedIdentity: model.groupId
        )

        // Full opacity while dragged: the freeform reorder suppresses the
        // floating ghost, so the row itself is the drag visual and must keep
        // its exact resting appearance (the dim was a ghost-era cue).
        alphaValue = 1
        updatePlusVisibility()
        updateRowHoverFill()
        setAccessibilityIdentifier("sidebarWorkspaceGroup.\(model.groupId.uuidString)")
        setAccessibilityLabel(model.name)
    }

    /// Live drop-line painting during native reorder drags; see
    /// `SidebarWorkspaceRowTableCellView.paintControllerDropIndicator`.
    func paintControllerDropIndicator(top: Bool, bottom: Bool) {
        let colorScheme: ColorScheme = model.map { $0.colorSchemeIsDark ? .dark : .light }
            ?? SidebarAppearanceColorResolver().currentColorScheme()
        let accent = (model?.accentColor ?? CmuxAccentColor()).nsColor(for: colorScheme)
        topDropIndicator.layer?.backgroundColor = accent.cgColor
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor
        topDropIndicator.isHidden = !top
        bottomDropIndicator.isHidden = !bottom
    }

#if DEBUG
    var dropIndicatorPaintForTesting: (top: Bool, bottom: Bool) {
        (!topDropIndicator.isHidden, !bottomDropIndicator.isHidden)
    }
#endif

    func updatePlusVisibility() {
        let showsHint = model?.shortcutHintText != nil
        plusButton.setRevealed(isPointerHovering && !contextMenuVisible && !showsHint)
    }

    /// Optimistic press treatment: paints the anchor-active header visuals
    /// instantly (group clicks focus the anchor workspace); the next
    /// authoritative configure reconciles.
    func showOptimisticAnchorActive() {
        guard let model, !model.isAnchorActive else { return }
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        let labelColor = SidebarAppearanceColorResolver().resolvedColor(.labelColor, for: colorScheme)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 4
        backgroundView.layer?.backgroundColor = labelColor.withAlphaComponent(0.08).cgColor
        applySelectionEdge(model.anchorActiveEdgeColor)
        CATransaction.commit()
        nameField.textColor = labelColor
        updateRowHoverFill()
    }

    /// Modifier-click preview: paints the same dim membership tint as an
    /// unfocused multi-selected workspace row.
    func showOptimisticMultiSelection() {
        guard let model, !model.isAnchorActive, !model.isMultiSelected else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 6
        backgroundView.layer?.backgroundColor = headerMultiSelectionBackgroundColor(for: model).cgColor
        applySelectionEdge(model.multiSelectionBackgroundStyle.edgeColor)
        CATransaction.commit()
        updateRowHoverFill()
    }

    /// Plain-click counterpart: clears active and multi-selected header paint
    /// while the authoritative single selection is applied.
    func showOptimisticDeselection() {
        guard let model, model.isAnchorActive || model.isMultiSelected else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.cornerRadius = 4
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        applySelectionEdge(nil)
        CATransaction.commit()
        let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
        nameField.textColor = SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: 0.9
        )
        updateRowHoverFill()
    }

    /// Rollback for optimistic press paint: reapplies the stored model
    /// unconditionally, mirroring the workspace cell. This must not skip
    /// active models — `showOptimisticDeselection` can clear a header whose
    /// model is still anchor-active, and a press that never produces an
    /// authoritative apply (swallowed, superseded, became a drag) would
    /// otherwise leave that header visually deselected until the next render.
    func restoreStoredModelPaint() {
        guard let model else { return }
        applyModel(model)
    }

    private func headerBackgroundColor(for model: SidebarGroupHeaderRowModel) -> NSColor {
        if model.isAnchorActive {
            let colorScheme: ColorScheme = model.colorSchemeIsDark ? .dark : .light
            if SidebarGlassSelection.usesStockLightLook(colorScheme) { return SidebarGlassSelection.fill(for: colorScheme) }
            return SidebarAppearanceColorResolver().resolvedColor(
                .labelColor,
                for: colorScheme,
                opacity: 0.08
            )
        }
        if model.isMultiSelected {
            return headerMultiSelectionBackgroundColor(for: model)
        }
        return .clear
    }

    /// Subtle-selection hairline, matching selected workspace rows.
    private func headerSelectionEdgeColor(for model: SidebarGroupHeaderRowModel) -> NSColor? {
        if model.isAnchorActive { return model.anchorActiveEdgeColor }
        if model.isMultiSelected { return model.multiSelectionBackgroundStyle.edgeColor }
        return nil
    }

    private func applySelectionEdge(_ edgeColor: NSColor?) {
        backgroundView.layer?.borderWidth = edgeColor == nil ? 0 : 1
        backgroundView.layer?.borderColor = edgeColor?.cgColor
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
        rowHoverLayer.frame = backgroundView.bounds
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

        if !statusGlyphView.isHidden {
            let side = GlobalFontMagnification.scaledSize(metrics.iconFontSize, percent: model.globalFontMagnificationPercent)
            badgeSize = NSSize(width: side, height: side)
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
        if !statusGlyphView.isHidden {
            statusGlyphView.frame = NSRect(
                x: x + min(ceil(nameSize.width), nameAvailable) + 6,
                y: midY - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            )
        }

        let topOffset: CGFloat = model.isFirstRow ? 0 : -(model.rowSpacing / 2)
        topDropIndicator.position(in: bounds, at: topOffset)
        let bottomInset = metrics.groupScopedBottomDropIndicatorLeadingInset
        bottomDropIndicator.position(
            in: bounds,
            at: bounds.height - SidebarReorderIndicatorView.thickness + model.rowSpacing / 2,
            leadingInset: bottomInset
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

    /// Group Color submenu, built like the workspace row's color menu: clear,
    /// a custom color prompt, then the named palette with swatches.
    private func makeColorMenuItem(
        model: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions
    ) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let palette = WorkspaceTabColorSettings.palette()
        // Clear only what the user set; a config color cannot be cleared here.
        if actions.customColorHex() != nil {
            let clearItem = menuItem(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color")) {
                actions.onSetColor(nil)
            }
            clearItem.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle", pointSize: 13, weight: nil
            )
            submenu.addItem(clearItem)
        }
        let customItem = menuItem(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…")) { [weak self] in
            guard let hex = WorkspaceCustomColorPrompt.run(
                currentHex: model.tintHex,
                presentingWindow: self?.window
            ) else { return }
            actions.onSetColor(hex)
        }
        customItem.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paintpalette", pointSize: 13, weight: nil
        )
        submenu.addItem(customItem)
        if !palette.isEmpty {
            submenu.addItem(.separator())
        }
        SidebarWorkspaceRowColorMenu(
            currentColorHex: model.tintHex,
            colorScheme: model.colorSchemeIsDark ? .dark : .light
        ).addPaletteItems(to: submenu, palette: palette) { hex in
            actions.onSetColor(hex)
        }
        let parent = menuItem(String(localized: "workspaceGroup.contextMenu.groupColor", defaultValue: "Group Color")) {}
        parent.submenu = submenu
        return parent
    }

    private func makeHeaderMenu() -> NSMenu {
        guard let model, let actions else { return NSMenu() }
        let menu = trackedMenu()
        // Resolve availability at menu-open time. The row may have retained an
        // older anchor snapshot while the group was being promoted, but the
        // action bundle owns the authoritative live notification check.
        let notificationState = actions.notificationState()
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
        menu.addItem(makeColorMenuItem(model: model, actions: actions))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markRead", defaultValue: "Mark Group as Read"),
            enabled: notificationState.canMarkRead,
            action: actions.onMarkRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markUnread", defaultValue: "Mark Group as Unread"),
            enabled: notificationState.canMarkUnread,
            action: actions.onMarkUnread
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            enabled: notificationState.hasLatestNotifications,
            action: actions.onClearLatestNotifications
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllRead", defaultValue: "Mark All Workspaces in Group as Read"),
            enabled: notificationState.canMarkAllRead,
            action: actions.onMarkAllRead
        ))
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.markAllUnread", defaultValue: "Mark All Workspaces in Group as Unread"),
            enabled: notificationState.canMarkAllUnread,
            action: actions.onMarkAllUnread
        ))
        menu.addItem(.separator())
        appendConfigAndDocsItems(to: menu)
        menu.addItem(.separator())
        if !model.isPinned || model.memberCount > 0 {
            menu.addItem(menuItem(
                String(localized: "workspaceGroup.contextMenu.ungroup", defaultValue: "Ungroup Workspaces"),
                action: actions.onUngroup
            ))
        }
        menu.addItem(menuItem(
            String(localized: "workspaceGroup.contextMenu.delete", defaultValue: "Delete Group"),
            action: actions.onDelete
        ))
        return menu
    }
}

/// AppKit rendition of the sidebar shortcut-hint capsule. The outer view owns
/// the shadow while the inner view clips its fill to the capsule; putting both
/// on one unclipped layer squares it off. Where `NSGlassEffectView` exists
/// (macOS 26) a glass capsule shows as a ``ShortcutHintPalette/glassRimWidth``
/// rim around the opaque center; before that the opaque fill carries a border.
/// The glass class is looked up at runtime so the file still builds with
/// Swift 6.0.
@MainActor
final class SidebarShortcutHintPillView: NSView {
    private static let horizontalPadding: CGFloat = 4
    private static let visibilityAnimationKey = "shortcutHintVisibility"

    private let glassView: NSView?
    private let fillView = NSView()
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
        glassView = (NSClassFromString("NSGlassEffectView") as? NSView.Type)?.init(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        if let glassView {
            addSubview(glassView)
        }
        fillView.wantsLayer = true
        fillView.layer?.masksToBounds = true
        fillView.layer?.borderWidth = glassView == nil ? 0.8 : 0
        addSubview(fillView)

        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
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
        colorScheme: ColorScheme,
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
        label.textColor = ShortcutHintPalette.foreground(for: colorScheme)
        fillView.layer?.backgroundColor = ShortcutHintPalette.background(for: colorScheme).cgColor
        fillView.layer?.borderColor = ShortcutHintPalette.border(for: colorScheme).cgColor
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
        if let glassView {
            glassView.frame = bounds
            glassView.setValue(radius, forKey: "cornerRadius")
            let rim = ShortcutHintPalette.glassRimWidth
            fillView.frame = bounds.insetBy(dx: rim, dy: rim)
            fillView.layer?.cornerRadius = radius - rim
        } else {
            fillView.frame = bounds
            fillView.layer?.cornerRadius = radius
        }
        label.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: 2)
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

        // Hints fade in and out (``ShortcutHintAnimation``), at once under
        // Reduce Motion.
        if reduceMotionProvider() {
            applyImmediateVisibility(revealed)
            return
        }
        if revealed {
            fadeIn()
            return
        }

        guard !isHidden else {
            layer?.opacity = 0
            return
        }
        fadeOut(generation: generation)
    }

    private func fadeIn() {
        guard let layer else { return }
        let currentOpacity = isHidden ? 0 : (layer.presentation()?.opacity ?? layer.opacity)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = Float(1)
        animation.duration = ShortcutHintAnimation.visibilityDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = false
        layer.opacity = 1
        layer.add(animation, forKey: Self.visibilityAnimationKey)
        CATransaction.commit()
    }

    private func applyImmediateVisibility(_ revealed: Bool) {
        layer?.removeAnimation(forKey: Self.visibilityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = revealed ? 1 : 0
        CATransaction.commit()
        isHidden = !revealed
    }

    private func fadeOut(generation: UInt64) {
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = 0
        animation.duration = ShortcutHintAnimation.visibilityDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.visibilityGeneration == generation,
                      !self.isRevealed else { return }
                self.isHidden = true
            }
        }
        layer.opacity = 0
        layer.add(animation, forKey: Self.visibilityAnimationKey)
        CATransaction.commit()
    }
}

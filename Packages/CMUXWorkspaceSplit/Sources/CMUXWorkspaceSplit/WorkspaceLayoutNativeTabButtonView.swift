import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class WorkspaceLayoutNativeTabButtonView: NSView, NSDraggingSource {
    private(set) var tab: WorkspaceLayout.Tab = WorkspaceLayout.Tab(title: "")
    var paneId: PaneID = PaneID()
    var isSelected: Bool = false
    var isPaneFocused: Bool = false
    var showsZoomIndicator: Bool = false
    var controlShortcutDigit: Int?
    var showsControlShortcutHint = false
    var shortcutModifierSymbol = "⌃"
    var splitAppearance: WorkspaceLayoutConfiguration.Appearance = .default
    var contextMenuState = TabContextMenuState(
        isPinned: false,
        isUnread: false,
        isBrowser: false,
        isTerminal: false,
        hasCustomTitle: false,
        canCloseToLeft: false,
        canCloseToRight: false,
        canCloseOthers: false,
        canMoveToLeftPane: false,
        canMoveToRightPane: false,
        isZoomed: false,
        hasSplits: false,
        shortcuts: [:]
    )
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onZoomToggle: (() -> Void)?
    var onContextAction: ((TabContextAction) -> Void)?
    var onBeginTabDrag: (() -> Void)?
    var onCancelTabDrag: (() -> Void)?

    let iconView = NSImageView(frame: .zero)
    let titleLabel = NSTextField(frame: .zero)
    let closeButton = WorkspaceLayoutHoverButton(frame: .zero)
    let zoomButton = WorkspaceLayoutHoverButton(frame: .zero)
    let pinView = NSImageView(frame: .zero)
    let dirtyDot = NSView(frame: .zero)
    let unreadDot = NSView(frame: .zero)
    let spinner = NSProgressIndicator(frame: .zero)
    let shortcutHintView = WorkspaceLayoutShortcutHintPillView(frame: .zero)
    var trackingArea: NSTrackingArea?
    var isHovered = false
    var isCloseHovered = false
    var isZoomHovered = false
    var isClosePressed = false
    var isZoomPressed = false
    var dragStartLocation: NSPoint?
    var dragStarted = false
    var spinnerTimer: Timer?
    var debugFixedSpinnerPhase: CGFloat?
    var iconUsesTemplateSymbol = false

    var usesSubviewChrome: Bool {
        WorkspaceLayoutTabChromeContentRenderer.current == .appKitSubviews
    }

    var usesSubviewTitleLabel: Bool {
        switch WorkspaceLayoutTabChromeTitleSource.current {
        case .label:
            return true
        case .draw:
            return false
        case .auto:
            return usesSubviewChrome && WorkspaceLayoutTabChromeSubviewTitleRenderer.current == .label
        }
    }

    var titleFontSize: CGFloat {
#if DEBUG
        splitAppearance.tabTitleFontSize + WorkspaceLayoutTabChromeDebugTuning.current.titlePointSizeDelta
#else
        splitAppearance.tabTitleFontSize
#endif
    }

    var accessoryFontSize: CGFloat {
        max(8, splitAppearance.tabTitleFontSize - 2)
    }

    var accessorySlotSize: CGFloat {
        min(TabBarMetrics.tabHeight, max(TabBarMetrics.closeButtonSize, ceil(accessoryFontSize + 4)))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDebugSettingsChanged),
            name: WorkspaceLayoutNotifications.tabChromeDebugSettingsDidChange,
            object: nil
        )

        titleLabel.cell = WorkspaceLayoutZeroPaddingTextFieldCell(textCell: "")
        titleLabel.font = .systemFont(ofSize: splitAppearance.tabTitleFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear
        titleLabel.alphaValue = 0
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.alphaValue = 0
        addSubview(iconView)

        closeButton.drawsCloseGlyph = false
        closeButton.rendersVisuals = false
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        closeButton.layer?.cornerRadius = TabBarMetrics.closeButtonSize / 2
        closeButton.layer?.masksToBounds = true
        closeButton.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.isCloseHovered = hovering
            self.refreshChrome()
        }
        closeButton.onPressedChanged = { [weak self] pressed in
            guard let self else { return }
            self.isClosePressed = pressed
            self.refreshChrome()
        }
        addSubview(closeButton)

        zoomButton.iconImage = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: String(
                localized: "workspace.menu.exitZoomPane",
                defaultValue: "Exit Zoom"
            )
        )
        zoomButton.iconSize = TabBarMetrics.closeIconSize
        zoomButton.rendersVisuals = false
        zoomButton.target = self
        zoomButton.action = #selector(handleZoomButton)
        zoomButton.layer?.cornerRadius = TabBarMetrics.closeButtonSize / 2
        zoomButton.layer?.masksToBounds = true
        zoomButton.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.isZoomHovered = hovering
            self.refreshChrome()
        }
        zoomButton.onPressedChanged = { [weak self] pressed in
            guard let self else { return }
            self.isZoomPressed = pressed
            self.refreshChrome()
        }
        addSubview(zoomButton)

        pinView.image = NSImage(
            systemSymbolName: "pin.fill",
            accessibilityDescription: String(
                localized: "workspace.accessibility.pinnedTab",
                defaultValue: "Pinned Tab"
            )
        )
        pinView.imageScaling = .scaleProportionallyDown
        pinView.alphaValue = 0
        addSubview(pinView)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = TabBarMetrics.dirtyIndicatorSize / 2
        dirtyDot.alphaValue = 0
        addSubview(dirtyDot)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = TabBarMetrics.notificationBadgeSize / 2
        unreadDot.alphaValue = 0
        addSubview(unreadDot)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.alphaValue = 0
        addSubview(spinner)

        shortcutHintView.alphaValue = 0
        shortcutHintView.isHidden = true
        addSubview(shortcutHintView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        spinnerTimer?.invalidate()
    }

    @objc private func handleDebugSettingsChanged() {
        if superview != nil {
            superview?.needsLayout = true
            superview?.needsDisplay = true
        }
        needsLayout = true
        refreshChrome()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    func update(
        tab: WorkspaceLayout.Tab,
        paneId: PaneID,
        isSelected: Bool,
        isPaneFocused: Bool,
        showsZoomIndicator: Bool,
        controlShortcutDigit: Int?,
        showsControlShortcutHint: Bool,
        shortcutModifierSymbol: String,
        appearance: WorkspaceLayoutConfiguration.Appearance,
        contextMenuState: TabContextMenuState,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onZoomToggle: @escaping () -> Void,
        onContextAction: @escaping (TabContextAction) -> Void,
        onBeginTabDrag: @escaping () -> Void,
        onCancelTabDrag: @escaping () -> Void
    ) {
        self.tab = tab
        self.paneId = paneId
        self.isSelected = isSelected
        self.isPaneFocused = isPaneFocused
        self.showsZoomIndicator = showsZoomIndicator
        self.controlShortcutDigit = controlShortcutDigit
        self.showsControlShortcutHint = showsControlShortcutHint
        self.shortcutModifierSymbol = shortcutModifierSymbol
        self.splitAppearance = appearance
        self.contextMenuState = contextMenuState
        self.onSelect = onSelect
        self.onClose = onClose
        self.onZoomToggle = onZoomToggle
        self.onContextAction = onContextAction
        self.onBeginTabDrag = onBeginTabDrag
        self.onCancelTabDrag = onCancelTabDrag

#if DEBUG
        let tuning = WorkspaceLayoutTabChromeDebugTuning.current
#else
        let tuning = (titlePointSizeDelta: CGFloat(0), titleKern: CGFloat(0), iconPointSizeDelta: CGFloat(-0.5))
#endif

        let titleFont = NSFont.systemFont(ofSize: titleFontSize)
        let titleColor = isSelected
            ? TabBarColors.nsColorActiveText(for: splitAppearance)
            : TabBarColors.nsColorInactiveText(for: splitAppearance)
        titleLabel.stringValue = tab.title
        titleLabel.font = titleFont
        titleLabel.textColor = titleColor

        if let imageData = tab.iconImageData,
           let image = NSImage(data: imageData) {
            image.isTemplate = false
            iconView.image = image
            iconView.contentTintColor = nil
            iconView.imageScaling = .scaleProportionallyDown
            iconUsesTemplateSymbol = false
        } else if let icon = tab.icon {
            iconView.image = workspaceSplitTemplateSymbolImage(
                named: icon,
                pointSize: symbolPointSize(for: icon) + tuning.iconPointSizeDelta,
                weight: .regular,
                fitting: CGSize(width: TabBarMetrics.iconSize, height: TabBarMetrics.iconSize)
            )
            iconView.contentTintColor = isSelected
                ? TabBarColors.nsColorActiveText(for: splitAppearance)
                : TabBarColors.nsColorInactiveText(for: splitAppearance)
            iconView.imageScaling = usesSubviewChrome ? .scaleNone : .scaleProportionallyDown
            iconUsesTemplateSymbol = true
        } else {
            iconView.image = nil
            iconUsesTemplateSymbol = false
        }

        let nextShowsShortcutHint = showsShortcutHint
        closeButton.isHidden = nextShowsShortcutHint || tab.isPinned || !(isSelected || isHovered || isCloseHovered)
        if closeButton.isHidden {
            isCloseHovered = false
            isClosePressed = false
        }
        pinView.isHidden = nextShowsShortcutHint || !tab.isPinned || closeButton.isHidden == false
        zoomButton.isHidden = !showsZoomIndicator
        if zoomButton.isHidden {
            isZoomHovered = false
            isZoomPressed = false
        }

        unreadDot.isHidden = nextShowsShortcutHint || isSelected || isHovered || isCloseHovered || !tab.showsNotificationBadge
        dirtyDot.isHidden = nextShowsShortcutHint || isSelected || isHovered || isCloseHovered || !tab.isDirty
        unreadDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dirtyDot.layer?.backgroundColor = TabBarColors.nsColorActiveText(for: splitAppearance).withAlphaComponent(0.72).cgColor

        if closeButton.rendersVisuals {
            closeButton.iconTintColor = (isCloseHovered || isClosePressed)
                ? TabBarColors.nsColorActiveText(for: splitAppearance)
                : TabBarColors.nsColorInactiveText(for: splitAppearance)
            closeButton.layer?.backgroundColor = closeButtonBackgroundColor().cgColor
        } else {
            closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        }
        if zoomButton.rendersVisuals {
            zoomButton.iconTintColor = (isZoomHovered || isZoomPressed)
                ? TabBarColors.nsColorActiveText(for: splitAppearance)
                : TabBarColors.nsColorInactiveText(for: splitAppearance)
            zoomButton.layer?.backgroundColor = zoomButtonBackgroundColor().cgColor
        } else {
            zoomButton.layer?.backgroundColor = NSColor.clear.cgColor
        }
        pinView.contentTintColor = TabBarColors.nsColorInactiveText(for: splitAppearance)
        titleLabel.alphaValue = usesSubviewTitleLabel ? 1 : 0
        iconView.alphaValue = usesSubviewChrome && !tab.isLoading && iconView.image != nil ? 1 : 0
        pinView.alphaValue = 0
        spinner.alphaValue = 0
        shortcutHintView.applyAppearance()
        if let shortcutHintLabel {
            shortcutHintView.update(
                text: shortcutHintLabel,
                fontSize: accessoryFontSize,
                textColor: isSelected
                    ? TabBarColors.nsColorActiveText(for: splitAppearance)
                    : TabBarColors.nsColorInactiveText(for: splitAppearance)
            )
        }
        if nextShowsShortcutHint != !shortcutHintView.isHidden {
            shortcutHintView.layer?.removeAllAnimations()
            shortcutHintView.isHidden = false
            let shouldRemainVisible = nextShowsShortcutHint
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shortcutHintView.animator().alphaValue = nextShowsShortcutHint ? 1 : 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                if !shouldRemainVisible {
                    self.shortcutHintView.isHidden = true
                }
            }
        } else {
            shortcutHintView.alphaValue = nextShowsShortcutHint ? 1 : 0
            shortcutHintView.isHidden = !nextShowsShortcutHint
        }
        syncSpinnerAnimation()

        needsLayout = true
        needsDisplay = true
    }

    func preferredWidth(minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleFontSize)
        ]
        let titleWidth = ceil((tab.title as NSString).size(withAttributes: titleAttributes).width)
        let trailingAccessoryWidth: CGFloat = showsZoomIndicator
            ? (accessorySlotSize + trailingAccessorySlotWidth)
            : trailingAccessorySlotWidth
        let titleToAccessorySpacing: CGFloat = showsZoomIndicator ? TabBarMetrics.contentSpacing : 0
        let chromeWidth =
            (TabBarMetrics.tabHorizontalPadding * 2)
            + TabBarMetrics.iconSize
            + TabBarMetrics.contentSpacing
            + trailingAccessoryWidth
            + titleToAccessorySpacing
        return min(maxWidth, max(minWidth, titleWidth + chromeWidth))
    }

    override func layout() {
        super.layout()
        let contentX = TabBarMetrics.tabHorizontalPadding
        let centerY = bounds.midY
#if DEBUG
        let tuning = WorkspaceLayoutTabChromeDebugTuning.current
#else
        let tuning = (titleDX: CGFloat(1), titleDY: CGFloat(0.375), iconDX: CGFloat(-1), iconDY: CGFloat(-0.875))
#endif

        let iconSlotRect = CGRect(
            x: contentX,
            y: centerY - (TabBarMetrics.iconSize / 2),
            width: TabBarMetrics.iconSize,
            height: TabBarMetrics.iconSize
        )
        if usesSubviewChrome, iconUsesTemplateSymbol, let image = iconView.image {
            iconView.frame = CGRect(
                x: round(iconSlotRect.midX - (image.size.width / 2) + tuning.iconDX),
                y: round(iconSlotRect.midY - (image.size.height / 2) + tuning.iconDY),
                width: image.size.width,
                height: image.size.height
            )
        } else {
            iconView.frame = iconSlotRect.offsetBy(dx: tuning.iconDX, dy: tuning.iconDY)
        }
        spinner.frame = CGRect(
            x: contentX,
            y: centerY - (TabBarMetrics.iconSize / 2),
            width: TabBarMetrics.iconSize,
            height: TabBarMetrics.iconSize
        )

        closeButton.frame = CGRect(
            x: bounds.maxX - TabBarMetrics.tabHorizontalPadding - trailingAccessorySlotWidth + ((trailingAccessorySlotWidth - accessorySlotSize) / 2),
            y: centerY - (accessorySlotSize / 2),
            width: accessorySlotSize,
            height: accessorySlotSize
        )
        closeButton.layer?.cornerRadius = closeButton.bounds.height / 2
        pinView.frame = closeButton.frame
        let shortcutHintSlotFrame = CGRect(
            x: bounds.maxX - TabBarMetrics.tabHorizontalPadding - trailingAccessorySlotWidth,
            y: centerY - (accessorySlotSize / 2),
            width: trailingAccessorySlotWidth,
            height: accessorySlotSize
        )
        shortcutHintView.frame = shortcutHintSlotFrame.offsetBy(dx: paneShortcutHintXOffset, dy: paneShortcutHintYOffset)

        if showsZoomIndicator {
            zoomButton.frame = CGRect(
                x: shortcutHintSlotFrame.minX - accessorySlotSize,
                y: centerY - (accessorySlotSize / 2),
                width: accessorySlotSize,
                height: accessorySlotSize
            )
            zoomButton.layer?.cornerRadius = zoomButton.bounds.height / 2
        } else {
            zoomButton.frame = .zero
        }

        let trailingAccessoryMinX = showsZoomIndicator ? zoomButton.frame.minX : shortcutHintSlotFrame.minX
        let titleMinX = iconSlotRect.maxX + TabBarMetrics.contentSpacing
        let titleMaxX = trailingAccessoryMinX - (showsZoomIndicator ? TabBarMetrics.contentSpacing : 0)
        let titleFrameMinX = titleMinX + tuning.titleDX + tuning.iconDX
        titleLabel.frame = CGRect(
            x: titleFrameMinX,
            y: centerY - 7 + tuning.titleDY,
            width: max(0, titleMaxX - titleFrameMinX),
            height: 14
        )
        let indicatorCenterX = closeButton.frame.midX
        let indicatorStartX = indicatorCenterX - (TabBarMetrics.notificationBadgeSize / 2)
        unreadDot.frame = CGRect(
            x: indicatorStartX,
            y: centerY - (TabBarMetrics.notificationBadgeSize / 2),
            width: TabBarMetrics.notificationBadgeSize,
            height: TabBarMetrics.notificationBadgeSize
        )
        dirtyDot.frame = CGRect(
            x: unreadDot.isHidden
                ? indicatorStartX
                : unreadDot.frame.maxX + 2,
            y: centerY - (TabBarMetrics.dirtyIndicatorSize / 2),
            width: TabBarMetrics.dirtyIndicatorSize,
            height: TabBarMetrics.dirtyIndicatorSize
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background: NSColor
        if isSelected {
            background = TabBarColors.nsColorPaneBackground(for: splitAppearance)
        } else if isHovered {
            background = workspaceSplitHoveredTabBackground(for: splitAppearance)
        } else {
            background = .clear
        }

        background.setFill()
        dirtyRect.fill()

        if isSelected {
            TabBarColors.nsColorSelectedIndicator(
                for: splitAppearance,
                focused: isPaneFocused
            ).setFill()
            CGRect(
                x: 0,
                y: bounds.height - TabBarMetrics.activeIndicatorHeight,
                width: max(0, bounds.width - 1),
                height: TabBarMetrics.activeIndicatorHeight
            ).fill()
        }

        TabBarColors.nsColorSeparator(for: splitAppearance).setFill()
        CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        drawTabChromeContent()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        refreshChrome()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isCloseHovered = false
        isZoomHovered = false
        isClosePressed = false
        isZoomPressed = false
        needsDisplay = true
        refreshChrome()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartLocation,
              !dragStarted,
              let onBeginTabDrag else { return }

        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - dragStartLocation.x, point.y - dragStartLocation.y)
        guard distance >= 3 else { return }
        dragStarted = true

        let transferTabId = tab.id
        onBeginTabDrag()

        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(
            TabTransferData(tabId: transferTabId, sourcePaneId: paneId.id)
        ) {
            pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.tabTransfer.identifier))
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = workspaceSplitSnapshotImage(for: self) ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartLocation = nil
            dragStarted = false
        }
        guard !dragStarted else { return }
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        workspaceSplitAddMenuItem(
            String(localized: "command.renameTab.title", defaultValue: "Rename Tab…"),
            action: .rename,
            to: menu,
            handler: onContextAction
        )

        if contextMenuState.hasCustomTitle {
            workspaceSplitAddMenuItem(
                String(localized: "workspace.menu.removeCustomTabName", defaultValue: "Remove Custom Tab Name"),
                action: .clearName,
                to: menu,
                handler: onContextAction
            )
        }

        menu.addItem(.separator())
        workspaceSplitAddMenuItem(
            String(localized: "workspace.menu.closeTabsToLeft", defaultValue: "Close Tabs to Left"),
            action: .closeToLeft,
            to: menu,
            enabled: contextMenuState.canCloseToLeft,
            handler: onContextAction
        )
        workspaceSplitAddMenuItem(
            String(localized: "workspace.menu.closeTabsToRight", defaultValue: "Close Tabs to Right"),
            action: .closeToRight,
            to: menu,
            enabled: contextMenuState.canCloseToRight,
            handler: onContextAction
        )
        workspaceSplitAddMenuItem(
            String(localized: "menu.file.closeOtherTabs", defaultValue: "Close Other Tabs in Pane"),
            action: .closeOthers,
            to: menu,
            enabled: contextMenuState.canCloseOthers,
            handler: onContextAction
        )
        workspaceSplitAddMenuItem(
            String(localized: "dialog.moveTab.title", defaultValue: "Move Tab"),
            action: .move,
            to: menu,
            handler: onContextAction
        )

        if contextMenuState.isTerminal {
            workspaceSplitAddMenuItem(
                String(localized: "workspace.menu.moveToLeftPane", defaultValue: "Move to Left Pane"),
                action: .moveToLeftPane,
                to: menu,
                enabled: contextMenuState.canMoveToLeftPane,
                handler: onContextAction
            )
            workspaceSplitAddMenuItem(
                String(localized: "workspace.menu.moveToRightPane", defaultValue: "Move to Right Pane"),
                action: .moveToRightPane,
                to: menu,
                enabled: contextMenuState.canMoveToRightPane,
                handler: onContextAction
            )
        }

        menu.addItem(.separator())
        workspaceSplitAddMenuItem(
            String(localized: "workspace.menu.newTerminalTabToRight", defaultValue: "New Terminal Tab to Right"),
            action: .newTerminalToRight,
            to: menu,
            handler: onContextAction
        )
        workspaceSplitAddMenuItem(
            String(localized: "workspace.menu.newBrowserTabToRight", defaultValue: "New Browser Tab to Right"),
            action: .newBrowserToRight,
            to: menu,
            handler: onContextAction
        )

        if contextMenuState.isBrowser {
            menu.addItem(.separator())
            workspaceSplitAddMenuItem(
                String(localized: "workspace.menu.reloadTab", defaultValue: "Reload Tab"),
                action: .reload,
                to: menu,
                handler: onContextAction
            )
            workspaceSplitAddMenuItem(
                String(localized: "workspace.menu.duplicateTab", defaultValue: "Duplicate Tab"),
                action: .duplicate,
                to: menu,
                handler: onContextAction
            )
        }

        menu.addItem(.separator())

        if contextMenuState.hasSplits {
            workspaceSplitAddMenuItem(
                contextMenuState.isZoomed
                    ? String(localized: "workspace.menu.exitZoomPane", defaultValue: "Exit Zoom")
                    : String(localized: "workspace.menu.zoomPane", defaultValue: "Zoom Pane"),
                action: .toggleZoom,
                to: menu,
                handler: onContextAction
            )
        }

        workspaceSplitAddMenuItem(
            contextMenuState.isPinned
                ? String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                : String(localized: "command.pinTab.title", defaultValue: "Pin Tab"),
            action: .togglePin,
            to: menu,
            handler: onContextAction
        )

        if contextMenuState.isUnread {
            workspaceSplitAddMenuItem(
                String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read"),
                action: .markAsRead,
                to: menu,
                enabled: contextMenuState.canMarkAsRead,
                handler: onContextAction
            )
        } else {
            workspaceSplitAddMenuItem(
                String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread"),
                action: .markAsUnread,
                to: menu,
                enabled: contextMenuState.canMarkAsUnread,
                handler: onContextAction
            )
        }

        menu.addItem(.separator())
        workspaceSplitAddMenuItem(
            String(localized: "command.copyIdentifiers.title", defaultValue: "Copy IDs"),
            action: .copyIdentifiers,
            to: menu,
            handler: onContextAction
        )

        return menu
    }

    @objc private func handleCloseButton() {
        onClose?()
    }

    @objc private func handleZoomButton() {
        onZoomToggle?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] {
            onCancelTabDrag?()
        }
    }

}

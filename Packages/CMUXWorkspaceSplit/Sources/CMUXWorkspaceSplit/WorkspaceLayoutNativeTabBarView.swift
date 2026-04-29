import AppKit
import UniformTypeIdentifiers

@MainActor
final class WorkspaceLayoutNativeTabBarView: NSView {
    var snapshot: WorkspaceLayoutPaneChromeSnapshot?
    var hostBridge: (WorkspaceLayoutInteractionHandlers)?
    var presentation: WorkspaceLayoutPresentationSnapshot?
    var localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    let shortcutHintMonitor = WorkspaceLayoutPaneTabShortcutHintMonitor()

    let scrollView = NSScrollView(frame: .zero)
    let documentView = WorkspaceLayoutTabDocumentView(frame: .zero)
    let splitButtonsView = NSStackView(frame: .zero)
    var tabButtons: [WorkspaceLayoutNativeTabButtonView] = []
    var trackingArea: NSTrackingArea?
    var isHovering = false
#if DEBUG
    var debugLastSnapshotSignature: String?
#endif

    var onTabMutation: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        addSubview(scrollView)

        splitButtonsView.orientation = .horizontal
        splitButtonsView.spacing = 4
        addSubview(splitButtonsView)

        documentView.onRequestRebuild = { [weak self] in
            self?.rebuildButtons()
        }
        documentView.onDropPerformed = { [weak self] in
            self?.onTabMutation?()
        }
        shortcutHintMonitor.onChange = { [weak self] in
            self?.rebuildButtons()
            self?.needsLayout = true
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateSplitButtonsVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateSplitButtonsVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shortcutHintMonitor.setHostWindow(window)
        if window != nil {
            shortcutHintMonitor.start()
        } else {
            shortcutHintMonitor.stop()
        }
    }

    func update(
        snapshot: WorkspaceLayoutPaneChromeSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        presentation: WorkspaceLayoutPresentationSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    ) {
        self.snapshot = snapshot
        self.hostBridge = hostBridge
        self.presentation = presentation
        self.localTabDrag = localTabDrag
        wantsLayer = true
        layer?.backgroundColor = TabBarColors.nsColorPaneBackground(
            for: presentation.appearance
        ).cgColor
#if DEBUG
        let selectedTitle = snapshot.tabs.first(where: { $0.tab.id.id == snapshot.selectedTabId })?.tab.title ?? ""
        let selectedPreview = snapshot.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "none"
        let signature =
            "pane=\(snapshot.paneId.id.uuidString.prefix(8)) " +
            "rev=\(snapshot.chromeRevision) " +
            "selected=\(selectedPreview) " +
            "title=\"\(workspaceLayoutDebugPreview(selectedTitle))\" " +
            "count=\(snapshot.tabs.count)"
        if debugLastSnapshotSignature != signature {
            debugLastSnapshotSignature = signature
        }
#endif
        documentView.update(
            snapshot: snapshot,
            hostBridge: hostBridge,
            presentation: presentation,
            localTabDrag: localTabDrag
        )
        rebuildButtons()
        rebuildSplitButtons()
        updateSplitButtonsVisibility()
        needsLayout = true
        needsDisplay = true
    }

    func updateLocalTabDrag(_ localTabDrag: WorkspaceLayoutLocalDragSnapshot?) {
        guard self.localTabDrag != localTabDrag else { return }
        self.localTabDrag = localTabDrag
        documentView.updateLocalTabDrag(localTabDrag)
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let buttonWidth = splitButtonsView.isHidden ? 0 : splitButtonsView.fittingSize.width + 8
        scrollView.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - buttonWidth), height: bounds.height)
        splitButtonsView.frame = CGRect(
            x: max(0, bounds.width - buttonWidth),
            y: 0,
            width: buttonWidth,
            height: bounds.height
        )
        documentView.frame = CGRect(origin: .zero, size: CGSize(width: max(scrollView.contentSize.width, documentView.preferredContentWidth), height: bounds.height))
        documentView.needsLayout = true
        documentView.layoutSubtreeIfNeeded()
        layer?.backgroundColor = TabBarColors.nsColorPaneBackground(
            for: presentation.appearance
        ).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let presentation else { return }
        let separatorColor = TabBarColors.nsColorSeparator(for: presentation.appearance)
        separatorColor.setFill()
        let segments = separatorSegments(
            totalWidth: bounds.width,
            gap: selectedTabSeparatorGap()
        )
        if segments.left > 0 {
            CGRect(x: 0, y: 0, width: segments.left, height: 1).fill()
        }
        if segments.right > 0 {
            CGRect(
                x: bounds.width - segments.right,
                y: 0,
                width: segments.right,
                height: 1
            ).fill()
        }
    }

    func separatorSegments(
        totalWidth: CGFloat,
        gap: ClosedRange<CGFloat>?
    ) -> (left: CGFloat, right: CGFloat) {
        let clampedTotal = max(0, totalWidth)
        guard let gap else {
            return (left: clampedTotal, right: 0)
        }

        let start = min(max(gap.lowerBound, 0), clampedTotal)
        let end = min(max(gap.upperBound, 0), clampedTotal)
        let normalizedStart = min(start, end)
        let normalizedEnd = max(start, end)
        return (
            left: max(0, normalizedStart),
            right: max(0, clampedTotal - normalizedEnd)
        )
    }

    func selectedTabSeparatorGap() -> ClosedRange<CGFloat>? {
        guard let snapshot else { return nil }
        let selectedId = snapshot.selectedTabId
        guard let selectedId,
              let selectedButton = tabButtons.first(where: { $0.tab.id.id == selectedId }) else {
            return nil
        }

        let frameInBar = convert(selectedButton.bounds, from: selectedButton)
        guard frameInBar.maxX > 0, frameInBar.minX < bounds.width else {
            return nil
        }
        return frameInBar.minX...frameInBar.maxX
    }

    func rebuildButtons() {
        guard let snapshot, let hostBridge, let presentation else { return }
        let showsControlShortcutHints = snapshot.isFocused &&
            presentation.tabShortcutHintsEnabled &&
            shortcutHintMonitor.isShortcutHintVisible

        let existingById = Dictionary(uniqueKeysWithValues: tabButtons.map { ($0.tab.id, $0) })
        var nextButtons: [WorkspaceLayoutNativeTabButtonView] = []

        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            let tab = tabSnapshot.tab
            let button = existingById[tab.id] ?? WorkspaceLayoutNativeTabButtonView(frame: .zero)
            button.update(
                tab: tabSnapshot.tab,
                paneId: snapshot.paneId,
                isSelected: tabSnapshot.isSelected,
                isPaneFocused: snapshot.isFocused,
                showsZoomIndicator: tabSnapshot.showsZoomIndicator,
                controlShortcutDigit: workspaceLayoutTabControlShortcutDigit(for: index, tabCount: snapshot.tabs.count),
                showsControlShortcutHint: showsControlShortcutHints,
                shortcutModifierSymbol: shortcutHintMonitor.shortcutModifierSymbol,
                appearance: presentation.appearance,
                contextMenuState: tabSnapshot.contextMenuState,
                onSelect: { [weak self] in
                    guard let self else { return }
                    _ = hostBridge.focusPane(snapshot.paneId)
                    hostBridge.selectTab(tab.id)
                    self.onTabMutation?()
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    guard !tab.isPinned else { return }
                    _ = hostBridge.requestCloseTab(tab.id, inPane: snapshot.paneId)
                    self.onTabMutation?()
                },
                onZoomToggle: { [weak self] in
                    guard let self else { return }
                    _ = hostBridge.togglePaneZoom(inPane: snapshot.paneId)
                    self.onTabMutation?()
                },
                onContextAction: { [weak self] action in
                    guard let self else { return }
                    hostBridge.requestTabContextAction(action, for: tab.id, inPane: snapshot.paneId)
                    self.onTabMutation?()
                },
                onBeginTabDrag: {
                    hostBridge.beginTabDrag(tabId: tab.id, sourcePaneId: snapshot.paneId)
                },
                onCancelTabDrag: {
                    hostBridge.clearDragState()
                }
            )
            nextButtons.append(button)
        }

        let nextIds = Set(nextButtons.map { $0.tab.id })
        for button in tabButtons where !nextIds.contains(button.tab.id) {
            button.removeFromSuperview()
        }

        tabButtons = nextButtons
        documentView.setTabButtons(tabButtons)
        documentView.needsLayout = true
        documentView.needsDisplay = true
        for button in tabButtons {
            button.needsLayout = true
            button.needsDisplay = true
        }
        needsLayout = true
        needsDisplay = true
        if let selected = snapshot.selectedTabId,
           let selectedButton = tabButtons.first(where: { $0.tab.id.id == selected }) {
            scrollView.contentView.scrollToVisible(selectedButton.frame.insetBy(dx: -32, dy: 0))
        }
    }

    func rebuildSplitButtons() {
        guard let snapshot, let hostBridge, let presentation else { return }

        splitButtonsView.subviews.forEach { $0.removeFromSuperview() }
        guard snapshot.showSplitButtons else { return }

        let appearance = presentation.appearance
        let tooltips = appearance.splitButtonTooltips

        splitButtonsView.addArrangedSubview(
            workspaceSplitMakeSymbolButton(
                symbolName: "terminal",
                tooltip: tooltips.newTerminal,
                color: TabBarColors.nsColorInactiveText(for: appearance)
            ) { [weak self] in
                hostBridge.requestNewTab(kind: .terminal, inPane: snapshot.paneId)
                self?.onTabMutation?()
            }
        )

        splitButtonsView.addArrangedSubview(
            workspaceSplitMakeSymbolButton(
                symbolName: "globe",
                tooltip: tooltips.newBrowser,
                color: TabBarColors.nsColorInactiveText(for: appearance)
            ) { [weak self] in
                hostBridge.requestNewTab(kind: .browser, inPane: snapshot.paneId)
                self?.onTabMutation?()
            }
        )

        splitButtonsView.addArrangedSubview(
            workspaceSplitMakeSymbolButton(
                symbolName: "square.split.2x1",
                tooltip: tooltips.splitRight,
                color: TabBarColors.nsColorInactiveText(for: appearance)
            ) { [weak self] in
                _ = hostBridge.splitPane(snapshot.paneId, orientation: .horizontal)
                self?.onTabMutation?()
            }
        )

        splitButtonsView.addArrangedSubview(
            workspaceSplitMakeSymbolButton(
                symbolName: "square.split.1x2",
                tooltip: tooltips.splitDown,
                color: TabBarColors.nsColorInactiveText(for: appearance)
            ) { [weak self] in
                _ = hostBridge.splitPane(snapshot.paneId, orientation: .vertical)
                self?.onTabMutation?()
            }
        )
    }

    func updateSplitButtonsVisibility() {
        guard let presentation, let snapshot else { return }
        let shouldShow = snapshot.showSplitButtons
            && (!presentation.isMinimalMode || isHovering || !presentation.appearance.splitButtonsOnHover)
        splitButtonsView.isHidden = !shouldShow
        needsLayout = true
    }
}

func workspaceSplitMakeSymbolButton(
    symbolName: String,
    tooltip: String,
    color: NSColor,
    action: @escaping () -> Void
) -> NSButton {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.image = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: tooltip
    )
    button.contentTintColor = color
    button.toolTip = tooltip
    let target = ClosureSleeve(action)
    button.target = target
    button.action = #selector(ClosureSleeve.invoke)
    objc_setAssociatedObject(
        button,
        &workspaceSplitClosureSleeveAssociationKey,
        target,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return button
}

var workspaceSplitClosureSleeveAssociationKey: UInt8 = 0

final class ClosureSleeve: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

@MainActor
final class WorkspaceLayoutTabDocumentView: NSView {
    var snapshot: WorkspaceLayoutPaneChromeSnapshot?
    var hostBridge: (WorkspaceLayoutInteractionHandlers)?
    var presentation: WorkspaceLayoutPresentationSnapshot?
    var localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    var tabButtons: [WorkspaceLayoutNativeTabButtonView] = []
    let dropIndicatorView = NSView(frame: .zero)

    var preferredContentWidth: CGFloat = 0
    var onRequestRebuild: (() -> Void)?
    var onDropPerformed: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)])
        dropIndicatorView.wantsLayer = true
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.isHidden = true
        addSubview(dropIndicatorView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        snapshot: WorkspaceLayoutPaneChromeSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        presentation: WorkspaceLayoutPresentationSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    ) {
        self.snapshot = snapshot
        self.hostBridge = hostBridge
        self.presentation = presentation
        self.localTabDrag = localTabDrag
    }

    func updateLocalTabDrag(_ localTabDrag: WorkspaceLayoutLocalDragSnapshot?) {
        self.localTabDrag = localTabDrag
    }

    func setTabButtons(_ buttons: [WorkspaceLayoutNativeTabButtonView]) {
        tabButtons.forEach { if !buttons.contains($0) { $0.removeFromSuperview() } }
        tabButtons = buttons
        for button in buttons where button.superview !== self {
            addSubview(button)
        }
        addSubview(dropIndicatorView)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let presentation else { return }
        let appearance = presentation.appearance
        let leadingInset = appearance.tabBarLeadingInset
        var x = leadingInset

        for button in tabButtons {
            let width = button.preferredWidth(
                minWidth: appearance.tabMinWidth,
                maxWidth: appearance.tabMaxWidth
            )
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + appearance.tabSpacing
        }

        preferredContentWidth = max(bounds.width, x + 30)
        frame.size = CGSize(width: preferredContentWidth, height: bounds.height)
    }

    func targetIndex(for point: NSPoint) -> Int {
        for (index, button) in tabButtons.enumerated() {
            if point.x < button.frame.midX {
                return index
            }
        }
        return tabButtons.count
    }

    func effectiveTargetIndex(for point: NSPoint) -> Int? {
        guard let snapshot else { return nil }
        let rawTargetIndex = targetIndex(for: point)
        return workspaceLayoutEffectiveTabDropTargetIndex(
            rawTargetIndex: rawTargetIndex,
            tabIds: snapshot.tabs.map(\.tab.id),
            paneId: snapshot.paneId,
            localTabDrag: localTabDrag
        )
    }

    func updateDropIndicator(targetIndex: Int?) {
        guard let targetIndex else {
            dropIndicatorView.isHidden = true
            return
        }

        let x: CGFloat
        if targetIndex >= tabButtons.count {
            x = (tabButtons.last?.frame.maxX ?? 0) - 1
        } else {
            x = tabButtons[targetIndex].frame.minX - 1
        }

        dropIndicatorView.frame = CGRect(
            x: x,
            y: max(0, (bounds.height - TabBarMetrics.dropIndicatorHeight) / 2),
            width: TabBarMetrics.dropIndicatorWidth,
            height: TabBarMetrics.dropIndicatorHeight
        )
        dropIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicatorView.isHidden = false
    }

    func validateSplitTabDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let presentation else { return false }
        guard presentation.isInteractive else { return false }
        if localTabDrag != nil {
            return true
        }
        guard let transfer = workspaceSplitDecodeTransfer(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
            return false
        }
        return sender.draggingPasteboard.availableType(from: [NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)]) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard validateSplitTabDrop(sender) else { return [] }
        let targetIndex = effectiveTargetIndex(for: convert(sender.draggingLocation, from: nil))
        updateDropIndicator(targetIndex: targetIndex)
        return targetIndex == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard validateSplitTabDrop(sender) else { return [] }
        let targetIndex = effectiveTargetIndex(for: convert(sender.draggingLocation, from: nil))
        updateDropIndicator(targetIndex: targetIndex)
        return targetIndex == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateDropIndicator(targetIndex: nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard validateSplitTabDrop(sender) else { return false }
        return effectiveTargetIndex(for: convert(sender.draggingLocation, from: nil)) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let snapshot, let hostBridge else { return false }
        guard let destinationIndex = effectiveTargetIndex(for: convert(sender.draggingLocation, from: nil)) else {
            updateDropIndicator(targetIndex: nil)
            return false
        }

        if let localDrag = localTabDrag {
            let draggedTabId = localDrag.tabId
            let sourcePaneId = localDrag.sourcePaneId
            if sourcePaneId == snapshot.paneId {
                _ = hostBridge.moveTab(
                    draggedTabId,
                    toPane: snapshot.paneId,
                    atIndex: destinationIndex
                )
                _ = hostBridge.focusPane(snapshot.paneId)
            } else {
                _ = hostBridge.moveTab(
                    draggedTabId,
                    toPane: snapshot.paneId,
                    atIndex: destinationIndex
                )
            }
            hostBridge.clearDragState()
            updateDropIndicator(targetIndex: nil)
            onDropPerformed?()
            return true
        }

        guard let transfer = workspaceSplitDecodeTransfer(from: sender.draggingPasteboard),
              transfer.isFromCurrentProcess else {
            updateDropIndicator(targetIndex: nil)
            return false
        }

        let request = WorkspaceLayoutExternalTabDropRequest(
            tabId: transfer.tabId,
            sourcePaneId: PaneID(id: transfer.sourcePaneId),
            destination: .insert(targetPane: snapshot.paneId, targetIndex: destinationIndex)
        )
        let handled = hostBridge.handleExternalTabDrop(request)
        updateDropIndicator(targetIndex: nil)
        if handled {
            onDropPerformed?()
        }
        return handled
    }
}

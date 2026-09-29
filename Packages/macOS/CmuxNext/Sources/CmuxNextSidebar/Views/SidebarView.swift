public import AppKit
import CmuxNextDesign
import Observation

/// Footer slots the App fills (account, cloud, status).
public enum SidebarAccessorySlot: CaseIterable, Sendable {
    case account
    case cloud
    case status
}

/// Result of hit-testing an external tab drag.
public struct SidebarTabDropHit: Hashable, Sendable {
    public var drop: SidebarTabDrop
    /// Highlighted row, group header, gap, or "new" button, in screen coordinates.
    public var highlightFrame: CGRect
}

/// The sidebar's content: titlebar button row, glass search field, the
/// workspace list, and footer accessory slots. Place it in a glass panel, or
/// use `SidebarContainerView`, which adds the panel, width, and resize handle.
public final class SidebarView: NSView, NSTextFieldDelegate {
    public let model: SidebarModel

    /// Height reserved at the top for the window's traffic lights. The
    /// toolbar buttons sit in this row, trailing.
    public var titlebarHeight: CGFloat = Metrics.titlebarHeight { didSet { needsLayout = true } }

    private let list: SidebarListView
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let clearButton = SidebarIconButton(symbol: "xmark.circle.fill", pointSize: Metrics.smallIconSize - Metrics.space1, weight: .regular, label: Strings.clearSearch)
    private let searchGlass: NSGlassEffectView
    private let searchContent = NSView()
    private let newButton = SidebarIconButton(symbol: "plus", label: Strings.newWorkspace)
    private let presentationButton = SidebarIconButton(symbol: "sidebar.left", weight: .regular, label: Strings.showIconsOnly)
    private let compactSearchButton = SidebarIconButton(symbol: "magnifyingglass", label: Strings.searchPlaceholder)
    private let emptyLabel = NSTextField(labelWithString: Strings.noMatches)
    private var accessories: [SidebarAccessorySlot: NSView] = [:]
    private let footer = NSView()
    private var observation: Task<Void, Never>?
    private var lastState: RenderState?

    public init(model: SidebarModel) {
        self.model = model
        list = SidebarListView(model: model)
        searchGlass = Glass.makePanel(content: searchContent, style: .clear, cornerRadius: Metrics.itemCornerRadius + Metrics.space1)
        super.init(frame: .zero)
        buildHierarchy()
        list.reload(animated: false)
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observation?.cancel()
    }

    override public var isFlipped: Bool { true }

    // MARK: Public API

    /// Installs (or removes, with nil) the view in a footer slot.
    public func setAccessory(_ view: NSView?, for slot: SidebarAccessorySlot) {
        accessories[slot]?.removeFromSuperview()
        accessories[slot] = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = true
            footer.addSubview(view)
        }
        needsLayout = true
    }

    /// Focuses the search field (Cmd-F style entry point for the App).
    public func focusSearch() {
        if model.presentation != .expanded { model.presentation = .expanded }
        window?.makeFirstResponder(searchField)
    }

    /// Focuses the workspace list for keyboard navigation.
    public func focusList() {
        window?.makeFirstResponder(list)
    }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.beginRename(.workspace(active))
    }

    // MARK: External tab drag (driven by the App's TabDragSession)

    /// Hover time before a tab drag over a workspace row selects it.
    public var springLoadDelay: Duration {
        get { list.springLoadDelay }
        set { list.springLoadDelay = newValue }
    }

    /// Clock for the spring-load delay (inject a test clock).
    public var springLoadClock: any Clock<Duration> {
        get { list.springLoadClock }
        set { list.springLoadClock = newValue }
    }

    /// Call on every pointer move of an in-app tab drag. Opens a gap, lights
    /// a row or group, spring-loads rows, and auto-scrolls near the edges.
    /// Returns nil when the point is outside the sidebar or cannot accept the
    /// tab; the sidebar then clears its drop visuals.
    /// - Parameter sourceMachine: the tab's daemon; drops stay on that machine.
    public func tabDragUpdate(screenPoint: CGPoint, sourceMachine: MachineID?) -> SidebarTabDropHit? {
        guard let window, model.presentation != .hidden, !isHiddenOrHasHiddenAncestor else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local) else {
            list.externalDragExited()
            return nil
        }
        if !newButton.isHidden, newButton.frame.insetBy(dx: -Metrics.space2, dy: -Metrics.space2).contains(local) {
            list.externalDragExited()
            let machine = sourceMachine ?? .local
            let index = model.section(.machine(machine))?.nodes.count ?? 0
            return SidebarTabDropHit(
                drop: .newWorkspace(section: .machine(machine), group: nil, index: index),
                highlightFrame: window.convertToScreen(convert(newButton.frame, to: nil))
            )
        }
        guard let (drop, rect) = list.externalDragMoved(windowPoint: windowPoint, sourceMachine: sourceMachine) else { return nil }
        return SidebarTabDropHit(drop: drop, highlightFrame: window.convertToScreen(list.convert(rect, to: nil)))
    }

    /// The drag left the sidebar or was cancelled (Escape).
    public func tabDragExited() {
        list.externalDragExited()
    }

    /// The drag was released. Returns the drop to commit, or nil. The App
    /// sends the daemon command and updates `model` (optimistically).
    @discardableResult
    public func tabDragEnded() -> SidebarTabDrop? {
        list.externalDragEnded()
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.glyphConfig)
        searchIcon.contentTintColor = Palette.textSecondary
        searchField.placeholderString = Strings.searchPlaceholder
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = Typography.body
        searchField.textColor = Palette.textPrimary
        searchField.delegate = self
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        clearButton.contentTintColor = Palette.textSecondary
        clearButton.isHidden = true
        clearButton.onPress = { [weak self] in self?.setFilter("") }
        [searchIcon, searchField, clearButton].forEach(searchContent.addSubview)
        searchGlass.translatesAutoresizingMaskIntoConstraints = true
        addSubview(searchGlass)

        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        presentationButton.onPress = { [weak self] in self?.model.togglePresentation() }
        compactSearchButton.onPress = { [weak self] in self?.focusSearch() }
        [newButton, presentationButton, compactSearchButton].forEach(addSubview)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)

        list.onTypeToSearch = { [weak self] text in
            guard let self else { return }
            self.focusSearch()
            self.setFilter(self.model.filterText + text)
            self.searchField.currentEditor()?.moveToEndOfDocument(nil)
        }

        emptyLabel.font = SidebarStyle.subtitleFont
        emptyLabel.textColor = Palette.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        addSubview(footer)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        list.realizeVisibleRows()
    }

    override public func layout() {
        super.layout()
        let b = bounds
        let compact = model.presentation == .iconsOnly
        var y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights.
        newButton.isHidden = compact
        presentationButton.isHidden = compact
        presentationButton.toolTip = compact ? Strings.showFull : Strings.showIconsOnly
        let button = SidebarStyle.toolbarButtonSize
        let rowY = max(Metrics.space2, (titlebarHeight - button) / 2)
        newButton.frame = NSRect(x: b.width - Metrics.space3 - button, y: rowY, width: button, height: button)
        presentationButton.frame = NSRect(x: newButton.frame.minX - Metrics.space1 - button, y: rowY, width: button, height: button)

        if compact {
            searchGlass.isHidden = true
            compactSearchButton.isHidden = false
            let side = Metrics.sidebarRowHeight
            compactSearchButton.frame = NSRect(x: (b.width - side) / 2, y: y, width: side, height: side)
            y += side + Metrics.space2
        } else {
            searchGlass.isHidden = false
            compactSearchButton.isHidden = true
            let inset = SidebarStyle.horizontalInset
            searchGlass.frame = NSRect(x: inset, y: y, width: max(0, b.width - inset * 2), height: SidebarStyle.searchHeight)
            searchGlass.layoutSubtreeIfNeeded()
            let content = searchContent.bounds
            let glyph = Metrics.smallIconSize
            searchIcon.frame = NSRect(x: Metrics.space4, y: (content.height - glyph) / 2, width: glyph, height: glyph)
            let control = SidebarStyle.controlSize
            clearButton.frame = NSRect(x: content.width - Metrics.space2 - control, y: (content.height - control) / 2, width: control, height: control)
            let fieldHeight = ceil(searchField.intrinsicContentSize.height)
            let fieldX = searchIcon.frame.maxX + Metrics.space3
            searchField.frame = NSRect(x: fieldX, y: (content.height - fieldHeight) / 2, width: max(0, clearButton.frame.minX - fieldX), height: fieldHeight)
            y += SidebarStyle.searchHeight + Metrics.space4
        }

        // Footer slots.
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in accessories[slot].map { (slot, $0) } }
        let slot = Metrics.sidebarRowHeight
        let footerHeight: CGFloat = visibleSlots.isEmpty ? 0 : (compact ? CGFloat(visibleSlots.count) * (slot + Metrics.space2) + Metrics.space4 : SidebarStyle.footerHeight)
        footer.frame = NSRect(x: 0, y: b.height - footerHeight, width: b.width, height: footerHeight)
        layoutFooter(visibleSlots, compact: compact)

        scrollView.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, b.height - y - footerHeight))
        list.setFrameSize(NSSize(width: scrollView.contentSize.width, height: list.frame.height))
        emptyLabel.frame = NSRect(x: Metrics.space4, y: y + Metrics.space6, width: max(0, b.width - Metrics.space6), height: Metrics.sidebarRowHeight)
    }

    private func layoutFooter(_ slots: [(SidebarAccessorySlot, NSView)], compact: Bool) {
        let f = footer.bounds
        if compact {
            for (i, (_, view)) in slots.enumerated() {
                let slot = Metrics.sidebarRowHeight
                view.frame = NSRect(x: (f.width - slot) / 2, y: Metrics.space2 + CGFloat(i) * (slot + Metrics.space2), width: slot, height: slot)
            }
            return
        }
        // account leading, cloud next to it, status fills the trailing space.
        let side = Metrics.sidebarRowHeight
        var x = Metrics.space4
        for (slot, view) in slots {
            let width: CGFloat
            switch slot {
            case .account, .cloud: width = side
            case .status: width = max(0, f.width - x - Metrics.space4)
            }
            view.frame = NSRect(x: x, y: (f.height - side) / 2, width: width, height: side)
            x += width + Metrics.space2
        }
    }

    // MARK: Observation

    /// Everything the list renders. Emitting a value type lets the list
    /// skip reloads when an unrelated model property changes.
    private struct RenderState: Hashable, Sendable {
        var sections: [SidebarSection]
        var selection: Set<WorkspaceID>
        var active: WorkspaceID?
        var filter: String
        var presentation: SidebarPresentation
    }

    private func observe() {
        let model = model
        observation = Task { [weak self] in
            for await state in Observations({
                RenderState(
                    sections: model.sections,
                    selection: model.selection,
                    active: model.activeWorkspaceID,
                    filter: model.filterText,
                    presentation: model.presentation
                )
            }) {
                self?.render(state)
            }
        }
    }

    private func render(_ state: RenderState) {
        guard state != lastState else { return }
        let presentationChanged = lastState?.presentation != state.presentation
        lastState = state
        if searchField.stringValue != state.filter { searchField.stringValue = state.filter }
        clearButton.isHidden = state.filter.isEmpty
        list.reload(animated: true)
        emptyLabel.isHidden = !(model.isFiltering && list.visibleWorkspaceOrder.isEmpty)
        if presentationChanged { needsLayout = true }
    }

    // MARK: Search field

    private func setFilter(_ text: String) {
        model.filterText = text
        if searchField.stringValue != text { searchField.stringValue = text }
        clearButton.isHidden = text.isEmpty
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField else { return }
        setFilter(searchField.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if model.filterText.isEmpty { focusList() } else { setFilter("") }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Activate the first match, keep the filter until the list is used.
            if let first = list.visibleWorkspaceOrder.first { model.click(first) }
            focusList()
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let first = list.visibleWorkspaceOrder.first { model.click(first) }
            focusList()
            return true
        default:
            return false
        }
    }
}

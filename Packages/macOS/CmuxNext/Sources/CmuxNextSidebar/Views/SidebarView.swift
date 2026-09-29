public import AppKit
import CmuxNextDesign
import Observation

/// Footer slots the App fills (account, cloud, status).
public enum SidebarAccessorySlot: CaseIterable, Sendable {
    case account
    case cloud
    case status
}

/// The sidebar's content: titlebar button row, glass search field, the
/// workspace list, and footer accessory slots. Place it in a glass panel, or
/// use `SidebarContainerView`, which adds the panel, width, and resize handle.
public final class SidebarView: NSView, NSTextFieldDelegate {
    public let model: SidebarModel

    /// Height reserved at the top for the window's traffic lights (the
    /// toolbar buttons sit in this row, trailing). Nil follows
    /// `Metrics.titlebarHeight`, read at layout time.
    public var titlebarHeightOverride: CGFloat? { didSet { needsLayout = true } }
    private var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }

    let list: SidebarListView
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let clearButton = SidebarIconButton(symbol: "xmark.circle.fill", pointSize: { Metrics.smallIconSize - Metrics.space1 }, weight: .regular, label: Strings.clearSearch)
    private let searchGlass: NSGlassEffectView
    private let searchContent = NSView()
    let newButton = SidebarIconButton(symbol: "plus", label: Strings.newWorkspace)
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

    /// Right-click menu for a target. The App fills this from the action
    /// registry (menus are ordered action-ID lists per context); nil means
    /// no context menu.
    public var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { list.contextMenuProvider }
        set { list.contextMenuProvider = newValue }
    }

    /// Starts inline rename of a workspace (the "rename workspace" action's
    /// sidebar entrypoint). Commit emits `.rename`.
    public func beginRename(workspace id: WorkspaceID) {
        list.beginRename(.workspace(id))
    }

    /// Starts inline rename of a group. Commit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.beginRename(.group(id))
    }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.beginRename(.workspace(active))
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        searchIcon.contentTintColor = Palette.textSecondary
        searchField.placeholderString = Strings.searchPlaceholder
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
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
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        // Sidebars keep overlay scrollers even when the system shows legacy
        // ones, so rows never reflow when the scroller appears.
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        addSubview(scrollView)

        list.onTypeToSearch = { [weak self] text in
            guard let self else { return }
            self.focusSearch()
            self.setFilter(self.model.filterText + text)
            self.searchField.currentEditor()?.moveToEndOfDocument(nil)
        }

        emptyLabel.textColor = Palette.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
        addSubview(footer)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        list.realizeVisibleRows()
    }

    @objc private func clipFrameChanged(_ note: Notification) {
        syncListWidth()
    }

    @objc private func scrollerStyleChanged(_ note: Notification) {
        scrollView.scrollerStyle = .overlay
        syncListWidth()
    }

    /// The list is always exactly as wide as the visible clip.
    private func syncListWidth() {
        let width = scrollView.contentView.bounds.width
        if list.frame.width != width { list.setFrameSize(NSSize(width: width, height: list.frame.height)) }
    }

    override public func layout() {
        super.layout()
        let b = bounds
        let compact = model.presentation == .iconsOnly
        var y = titlebarHeight
        // Tokens are read here, never cached, so density changes apply live.
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(SidebarStyle.glyphConfig)
        searchField.font = Typography.body
        emptyLabel.font = SidebarStyle.subtitleFont

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
        // Icons-only shows the icon slots; the status text needs width.
        for (slot, view) in accessories { view.isHidden = compact && slot == .status }
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in
            accessories[slot].flatMap { view in view.isHidden ? nil : (slot, view) }
        }
        let slot = Metrics.sidebarRowHeight
        let footerHeight: CGFloat = visibleSlots.isEmpty ? 0 : (compact ? CGFloat(visibleSlots.count) * (slot + Metrics.space2) + Metrics.space4 : SidebarStyle.footerHeight)
        footer.frame = NSRect(x: 0, y: b.height - footerHeight, width: b.width, height: footerHeight)
        layoutFooter(visibleSlots, compact: compact)

        scrollView.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, b.height - y - footerHeight))
        scrollView.tile()
        syncListWidth()
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
        /// Design tokens (density, overrides, chrome font size). Reading them
        /// inside the tracked closure makes a settings change re-render.
        var metrics: SidebarLayoutMetrics
        var fontSize: CGFloat
        var titlebarHeight: CGFloat
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
                    presentation: model.presentation,
                    metrics: model.presentation == .iconsOnly ? .iconsOnly : .standard,
                    fontSize: Typography.body.pointSize,
                    titlebarHeight: Metrics.titlebarHeight
                )
            }) {
                self?.render(state)
            }
        }
    }

    private func render(_ state: RenderState) {
        guard state != lastState else { return }
        let chromeChanged = lastState?.presentation != state.presentation
            || lastState?.metrics != state.metrics
            || lastState?.fontSize != state.fontSize
            || lastState?.titlebarHeight != state.titlebarHeight
        lastState = state
        if searchField.stringValue != state.filter { searchField.stringValue = state.filter }
        clearButton.isHidden = state.filter.isEmpty
        list.reload(animated: true)
        emptyLabel.isHidden = !(model.isFiltering && list.visibleWorkspaceOrder.isEmpty)
        if chromeChanged { needsLayout = true }
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

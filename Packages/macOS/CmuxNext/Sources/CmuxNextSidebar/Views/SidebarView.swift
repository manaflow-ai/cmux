public import AppKit
import CmuxNextDesign
import Observation

/// Footer slots the App fills (account, cloud, status).
public enum SidebarAccessorySlot: CaseIterable, Sendable {
    case account
    case cloud
    case status
}

/// The sidebar's content: the titlebar row (its buttons appear on hover),
/// the workspace list, and footer accessory slots. Workspace search lives in
/// the command palette (Go to Workspace), not here. Place it in a glass
/// panel, or use `SidebarContainerView`, which adds the panel, width, and
/// resize handle.
public final class SidebarView: NSView {
    public let model: SidebarModel

    /// Height reserved at the top for the window's traffic lights (the
    /// toolbar buttons sit in this row, trailing). Nil follows
    /// `Metrics.titlebarHeight`, read at layout time.
    public var titlebarHeightOverride: CGFloat? { didSet { needsLayout = true } }
    private var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }

    let list: SidebarListView
    private let scrollView = NSScrollView()
    let newButton = SidebarIconButton(symbol: "plus", label: Strings.newWorkspace)
    private let presentationButton = SidebarIconButton(symbol: "sidebar.left", weight: .regular, label: Strings.showIconsOnly)
    /// Pointer over the sidebar (or a tab drag over it): titlebar buttons show.
    private(set) var isChromeRevealed = false
    private var accessories: [SidebarAccessorySlot: NSView] = [:]
    private let footer = NSView()
    private var observation: Task<Void, Never>?
    private var lastState: RenderState?

    public init(model: SidebarModel) {
        self.model = model
        list = SidebarListView(model: model)
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
        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        presentationButton.onPress = { [weak self] in self?.model.togglePresentation() }
        for button in [newButton, presentationButton] {
            button.alphaValue = 0
            addSubview(button)
        }

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
        // Tokens are read here, never cached, so density changes apply live.
        // The list starts right under the titlebar row: no search field.
        let y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights, shown on hover.
        newButton.isHidden = compact
        presentationButton.isHidden = compact
        presentationButton.toolTip = compact ? Strings.showFull : Strings.showIconsOnly
        let button = SidebarStyle.toolbarButtonSize
        let rowY = max(Metrics.space2, (titlebarHeight - button) / 2)
        newButton.frame = NSRect(x: b.width - Metrics.space3 - button, y: rowY, width: button, height: button)
        presentationButton.frame = NSRect(x: newButton.frame.minX - Metrics.space1 - button, y: rowY, width: button, height: button)

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
    }

    // MARK: Hover reveal

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override public func mouseEntered(with event: NSEvent) { setChromeRevealed(true) }
    override public func mouseExited(with event: NSEvent) { setChromeRevealed(false) }

    /// Fades the titlebar buttons in or out. Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    func setChromeRevealed(_ revealed: Bool) {
        guard revealed != isChromeRevealed else { return }
        isChromeRevealed = revealed
        let alpha: CGFloat = revealed ? 1 : 0
        Motion.animate(Motion.fade) {
            newButton.animator().alphaValue = alpha
            presentationButton.animator().alphaValue = alpha
        }
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
        list.reload(animated: true)
        if chromeChanged { needsLayout = true }
    }
}

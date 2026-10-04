public import AppKit
public import CmuxNextDesign
public import CmuxNextResources
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
    /// Where the titlebar row's accessory may start: after the window's
    /// toolbar band (R68).
    public var titlebarLeadingReserve: CGFloat = 0 { didSet { if oldValue != titlebarLeadingReserve { needsLayout = true } } }
    private var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }

    let list: SidebarListView
    private let scrollView = SidebarScrollView()
    /// Hosts the list's scroll view and fades rows out at its top or bottom
    /// while more are hidden there.
    private var edgeFade: ScrollEdgeFadeView!
    /// No rubber band while every row fits.
    private var scrollFit: ScrollFitElasticity?
    let profileBar: ProfileBarView
    /// Item sections above and below the workspace list
    /// (plans/cmux-next/sidebar-sections.md); each scrolls inside past its
    /// share of the height.
    let aboveRegion = SidebarRegionView(region: .top)
    let belowRegion = SidebarRegionView(region: .bottom)
    let aboveScroll = NSScrollView()
    let belowScroll = NSScrollView()
    /// Fade the bands' rows out at an edge while more are hidden there.
    var aboveFade: ScrollEdgeFadeView!
    var belowFade: ScrollEdgeFadeView!
    /// Hairlines between the sticky bands and the list (quiet look).
    let aboveLine = CALayer()
    let belowLine = CALayer()
    let newButton = SidebarIconButton(symbol: "plus", label: Strings.newWorkspace)
    /// Pointer over the sidebar (or a tab drag over it): titlebar buttons show.
    var isChromeRevealed = false
    /// Bands minimal mode hides right now (the fade's target, R54).
    var minimalHiddenBands: (top: Bool, bottom: Bool) = (false, false)
    private var accessories: [SidebarAccessorySlot: NSView] = [:]
    private let footer = NSView()
    private var observation: Task<Void, Never>?
    private var lastState: RenderState?

    public init(model: SidebarModel) {
        self.model = model
        list = SidebarListView(model: model)
        profileBar = ProfileBarView(model: model)
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

    /// An inline rename ended (commit or cancel). `byKeyboard` is true for
    /// Return, Escape or Tab; the host can return focus to its content.
    public var onRenameEnded: ((_ byKeyboard: Bool) -> Void)? {
        get { list.inlineRename.onEnded }
        set { list.inlineRename.onEnded = newValue }
    }

    /// A small view in the titlebar row, after the traffic lights (an
    /// incognito window's badge). Nil removes it.
    public var titlebarAccessory: NSView? {
        didSet {
            guard oldValue !== titlebarAccessory else { return }
            oldValue?.removeFromSuperview()
            if let titlebarAccessory {
                titlebarAccessory.translatesAutoresizingMaskIntoConstraints = true
                addSubview(titlebarAccessory)
            }
            needsLayout = true
        }
    }

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

    /// CPU and memory for the workspace hover card. Sampled only while a
    /// card is pending or shown.
    public var resourceSource: (any ResourceSampleSource)? {
        get { list.hoverCard.resources.source }
        set { list.hoverCard.resources.setSource(newValue) }
    }

    /// Shows workspace `id`'s hover card (CPU and memory) now, until the
    /// next key press, click or scroll. False when its row is not shown.
    @discardableResult
    public func showHoverCard(for id: WorkspaceID) -> Bool {
        list.showHoverCard(for: id)
    }

    /// Draws the sections apps contribute (`SectionContent.app`); the App
    /// injects one per window. Without it, app sections draw nothing.
    public var appSections: (any SidebarAppSectionProvider)? {
        didSet {
            appSections?.onContentChange = { [weak self] in self?.needsLayout = true }
            for region in [aboveRegion, belowRegion] {
                region.appView = { [weak self] section in section.contribution.flatMap { self?.appSections?.makeView(for: $0) } }
            }
            needsLayout = true
        }
    }

    /// The app's one hover card coordinator (the App injects it).
    public var hoverCards: HoverCardCoordinator {
        get { list.hoverCards }
        set { list.hoverCards = newValue }
    }

    /// True while the workspace hover card samples resources.
    public var isSamplingResources: Bool { list.hoverCard.resources.isOpen }

    /// Right-click menu for a target. The App fills this from the action
    /// registry (menus are ordered action-ID lists per context); nil means
    /// no context menu.
    public var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { list.contextMenuProvider }
        set {
            list.contextMenuProvider = newValue
            profileBar.contextMenuProvider = newValue
            aboveRegion.contextMenuProvider = newValue
            belowRegion.contextMenuProvider = newValue
        }
    }

    /// Starts inline rename of a workspace (the "rename workspace" action's
    /// sidebar entrypoint). Commit emits `.rename`.
    public func beginRename(workspace id: WorkspaceID) {
        list.inlineRename.begin(.workspace(id))
    }

    /// Starts inline rename of a group. Commit emits `.renameGroup`.
    public func beginRename(group id: GroupID) {
        list.inlineRename.begin(.group(id))
    }

    /// Starts inline rename of the active workspace.
    public func renameActiveWorkspace() {
        guard let active = model.activeWorkspaceID else { return }
        list.inlineRename.begin(.workspace(active))
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        newButton.alphaValue = 0
        addSubview(newButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        // Sidebars keep overlay scrollers even when the system shows legacy
        // ones, so rows never reflow when the scroller appears.
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        scrollView.onHorizontalSwipe = { [weak self] delta in self?.model.stepProfile(by: delta) }
        edgeFade = ScrollEdgeFadeView(scrollView: scrollView)
        addSubview(edgeFade)
        scrollFit = ScrollFitElasticity(scrollView: scrollView)
        buildBands()

        addSubview(footer)
        footer.addSubview(profileBar)
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
        // Tokens are read here, never cached, so density changes apply live.
        // The list starts right under the titlebar row: no search field.
        let y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights, shown on hover.
        let button = SidebarStyle.toolbarButtonSize
        let rowY = max(Metrics.space2, (titlebarHeight - button) / 2)
        newButton.frame = NSRect(x: b.width - Metrics.space3 - button, y: rowY, width: button, height: button)
        if let accessory = titlebarAccessory {
            let size = accessory.fittingSize
            let x = max(Metrics.trafficLightInset, titlebarLeadingReserve)
            let width = max(0, min(size.width, newButton.frame.minX - Metrics.space2 - x))
            accessory.frame = NSRect(x: x, y: (titlebarHeight - size.height) / 2, width: width, height: size.height)
            accessory.isHidden = width < size.height
        }

        // Footer slots.
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in
            accessories[slot].flatMap { view in view.isHidden ? nil : (slot, view) }
        }
        let showsProfiles = ProfileBarLogic.isVisible(profileCount: model.profiles.count)
        profileBar.isHidden = !showsProfiles
        let footerHeight: CGFloat = visibleSlots.isEmpty && !showsProfiles ? 0 : SidebarStyle.footerHeight
        footer.frame = NSRect(x: 0, y: b.height - footerHeight, width: b.width, height: footerHeight)
        layoutFooter(visibleSlots)
        profileBar.frame = footer.bounds
        profileBar.refresh()

        let listFrame = layoutBands(top: y, footerHeight: footerHeight)
        edgeFade.frame = listFrame
        scrollView.tile()
        syncListWidth()
    }


    // MARK: Titlebar row

    /// The header row beside the traffic lights is titlebar: it moves the
    /// window, and a double-click zooms or minimizes (the user's macOS
    /// setting). Its buttons take their own clicks.
    override public func mouseDown(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).y < titlebarHeight else { return super.mouseDown(with: event) }
        WindowTitlebar.handleMouseDown(event, in: window)
    }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover reveal

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override public func mouseEntered(with event: NSEvent) { setChromeRevealed(true) }
    override public func mouseExited(with event: NSEvent) { setChromeRevealed(false) }

    private func layoutFooter(_ slots: [(SidebarAccessorySlot, NSView)]) {
        let f = footer.bounds
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
        var profiles: [SidebarProfile]
        var activeProfile: ProfileKey?
        var filter: String
        var layout: SidebarLayoutDocument
        var itemInfo: [LayoutItemID: SidebarItemInfo]
        var collapsedSections: Set<LayoutSectionID>
        var look: SectionsLookVariant
        var drawsLines: Bool
        var preferences: SidebarSectionsPreferences
        var suppressedApps: Set<String>
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
                    profiles: model.profiles,
                    activeProfile: model.activeProfileID,
                    filter: model.filterText,
                    layout: model.layout,
                    itemInfo: model.itemInfo,
                    collapsedSections: model.collapsedLayoutSections,
                    look: SidebarSectionTunables.currentLook,
                    drawsLines: Borders.drawsLines,
                    preferences: DesignSettings.shared.sidebarSections,
                    suppressedApps: model.suppressedApps,
                    metrics: .standard,
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
        let chromeChanged = lastState?.metrics != state.metrics || lastState?.fontSize != state.fontSize
            || lastState?.titlebarHeight != state.titlebarHeight
        let profileChanged = lastState?.activeProfile != state.activeProfile
        let profilesChanged = lastState?.profiles != state.profiles || profileChanged
            || lastState?.layout != state.layout || lastState?.itemInfo != state.itemInfo
            || lastState?.collapsedSections != state.collapsedSections || lastState?.look != state.look
            || lastState?.drawsLines != state.drawsLines || lastState?.preferences != state.preferences || lastState?.suppressedApps != state.suppressedApps
        let listChanged = lastState?.sections != state.sections || lastState?.selection != state.selection
            || lastState?.active != state.active || lastState?.filter != state.filter || chromeChanged || profileChanged
            || lastState?.preferences.showWorkspaceTabs != state.preferences.showWorkspaceTabs
        let previous = lastState?.sections
        model.showWorkspaceTabs = state.preferences.showWorkspaceTabs
        // Minimal mode changed: show or hide the chosen bands now.
        if lastState?.preferences.minimalMode != state.preferences.minimalMode { setChromeRevealed(isChromeRevealed) }
        if listChanged {
            if profileChanged, let previousProfile = lastState?.activeProfile, let nextProfile = state.activeProfile,
               let oldIndex = state.profiles.firstIndex(where: { $0.id == previousProfile }), let newIndex = state.profiles.firstIndex(where: { $0.id == nextProfile }),
               oldIndex != newIndex {
                animateProfileSwitch(on: list, towardNext: newIndex > oldIndex)
            }
            list.reload(animated: Self.animatesReload(from: previous, to: state.sections))
        }
        if chromeChanged || profilesChanged { needsLayout = true }
        lastState = state
    }

    /// Whether a sections change animates its rows. Provisional rows swap in place.
    static func animatesReload(from old: [SidebarSection]?, to new: [SidebarSection]) -> Bool {
        !((old ?? []) + new).contains(where: \.hasProvisionalRows)
    }
}

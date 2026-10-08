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
/// The sidebar's content: the titlebar row (its buttons remain mounted),
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
    /// False when the traffic lights are not over this header (a right
    /// sidebar, R109): the accessory then starts at the reserve alone.
    public var headerHasWindowControls = true { didSet { if oldValue != headerHasWindowControls { needsLayout = true } } }
    var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }
    let list: SidebarListView
    let scrollView = SidebarScrollView()
    private(set) lazy var spacePaging = SidebarSpacePaging(host: self)
    /// Hosts the list's scroll view and fades rows out at its top or bottom
    /// while more are hidden there.
    private var edgeFade: ScrollEdgeFadeView!
    /// No rubber band while every row fits.
    private var scrollFit: ScrollFitElasticity?
    let profileBar: ProfileBarView
    /// Item sections above and below the workspace list
    /// (plans/cmux-next/sidebar-sections.md); each scrolls inside past its
    /// share of the height. The footer section never scrolls: it is pinned
    /// at the bottom, under the band below (`footerRegion`).
    let aboveRegion = SidebarRegionView(region: .top)
    let belowRegion = SidebarRegionView(region: .bottom)
    let footerRegion = SidebarRegionView(region: .bottom)
    let aboveScroll = NSScrollView()
    let belowScroll = NSScrollView()
    /// Fade the bands' rows out at an edge while more are hidden there.
    var aboveFade: ScrollEdgeFadeView!
    var belowFade: ScrollEdgeFadeView!
    /// The hairline between the top band and the list (quiet look). The
    /// footer has none (SIDEBAR-FOOTER-MINIMAL).
    let aboveLine = CALayer()
    let newButton = SidebarIconButton(symbol: "plus", label: Strings.newWorkspace)
    let cardStack = SidebarCardStackView()
    /// Pointer over the sidebar (or a tab drag over it): titlebar buttons show.
    var isChromeRevealed = false
    /// The pointer over the sidebar now (cx-3wu5).
    private(set) var chromeHover: PointerHover?
    /// Bands minimal mode hides right now (the fade's target, R54).
    var minimalHiddenBands: (top: Bool, bottom: Bool) = (false, false)
    var accessories: [SidebarAccessorySlot: NSView] = [:]
    let footer = NSView()
    let updateCardView = SidebarUpdateCardView(), tipCardView = SidebarTipCardView() // SidebarBottomCards
    /// Back, in the footer band's spot while a destination is open (`SidebarView+Footer`).
    let backButton = SidebarBackButton()
    /// Where the spaces dots sit (`sidebar.spacesPosition`, R109).
    public var spacesPosition: SpacesPosition = .bottom {
        didSet { if spacesPosition != oldValue { needsLayout = true } }
    }
    /// When the spaces strip shows (`sidebar.spacesVisibility`, cx-5k3r):
    /// on hover it fades with the sidebar's other hover chrome.
    public var spacesVisibility: SpacesVisibilityMode = .hover {
        didSet { if spacesVisibility != oldValue { profileBar.alphaValue = spacesAlpha(revealed: isChromeRevealed) } }
    }
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
        // The chrome reveal follows the pointer and the sidebar's frame (cx-3wu5).
        chromeHover = PointerHover(self) { [weak self] hovering in self?.setChromeRevealed(hovering) }
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
    /// The sidebar's chrome reveal changed (the window's title bar buttons follow).
    public var onChromeRevealChange: ((Bool) -> Void)?
    /// The update and announcement cards above the spaces dots (R114; the updates lead fills it).
    public var footerCards: NSView?
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
            for region in bandRegions {
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
    /// The profile menu the footer's profile control opens
    /// (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2); the App builds it from
    /// registry actions. Nil opens nothing.
    public var profileMenuProvider: (() -> NSMenu?)?
    /// Shows a profile menu over its anchor (tests record it instead).
    var profileMenuPresenter: @MainActor (NSMenu, NSView?) -> Void = { SidebarView.popUpProfileMenu($0, from: $1) }

    /// no context menu.
    public var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { list.contextMenuProvider }
        set {
            list.contextMenuProvider = newValue
            profileBar.contextMenuProvider = newValue
            for region in bandRegions { region.contextMenuProvider = newValue }
        }
    }

    /// Starts inline rename of a workspace (the "rename workspace" action's
    /// sidebar entrypoint). Commit emits `.rename`.
    public func beginRename(workspace id: WorkspaceID) {
        list.inlineRename.begin(.workspace(id))
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        newButton.alphaValue = 0
        addSubview(newButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // The system's "Show scroll bars" setting (R111); the list follows
        // the clip's width when a legacy scroller narrows it.
        SystemScrollers.follow(scrollView)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        scrollView.onHorizontalScroll = { [weak self] phase, dx, time in self?.spacePaging.scroll(phase, deltaX: dx, time: time) }
        edgeFade = ScrollEdgeFadeView(scrollView: scrollView)
        addSubview(edgeFade)
        scrollFit = ScrollFitElasticity(scrollView: scrollView)
        buildBands()

        addSubview(footer)
        installBackButton()
        footer.addSubview(profileBar)
        profileBar.alphaValue = spacesAlpha(revealed: isChromeRevealed)
        cardSlot.install(in: self)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        list.realizeVisibleRows()
        PointerHover.refresh(in: window)
    }

    @objc private func clipFrameChanged(_ note: Notification) {
        syncListSize()
    }

    @objc private func scrollerStyleChanged(_ note: Notification) {
        scrollView.scrollerStyle = SystemScrollers.preferredStyle
        syncListSize()
    }

    /// The list follows the visible clip (`SidebarListView.fitToClip`).
    private func syncListSize() { list.fitToClip() }

    override public func layout() {
        super.layout()
        let b = bounds
        // Tokens are read here, never cached, so density changes apply live.
        // The list starts right under the titlebar row: no search field.
        let y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights at a stable frame.
        let button = SidebarStyle.toolbarButtonSize
        let rowY = max(Metrics.space2, (titlebarHeight - button) / 2)
        newButton.frame = NSRect(x: b.width - Metrics.space3 - button, y: rowY, width: button, height: button)
        if let accessory = titlebarAccessory {
            let size = accessory.fittingSize
            let x = headerHasWindowControls ? max(Metrics.trafficLightInset, titlebarLeadingReserve) : titlebarLeadingReserve
            let width = max(0, min(size.width, newButton.frame.minX - Metrics.space2 - x))
            accessory.frame = NSRect(x: x, y: (titlebarHeight - size.height) / 2, width: width, height: size.height)
            accessory.isHidden = width < size.height
        }

        // Footer slots.
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in
            accessories[slot].flatMap { view in view.isHidden ? nil : (slot, view) }
        }
        let showsProfiles = true
        profileBar.isHidden = false
        // R109: the dots under the titlebar row, or in the footer.
        let spacesHeight: CGFloat = spacesPosition == .top && showsProfiles ? SidebarStyle.footerHeight : 0
        // Amendment 3: at the bottom the dots share the footer band's row
        // (after the profile control), so the dots row takes no height of
        // its own unless the band is empty.
        updateBands()
        let footerHeight: CGFloat = spacesPosition == .bottom && dotsShareBandRow ? 0 : SidebarStyle.footerHeight
        let cardsHeight = attachFooterCards(), updateHeight = cardSlot.height
        // From the bottom up (R112/R114): the pinned footer section (the
        // profile control, then the dots), the band below the list, the
        // staged update card (UPDATE-CARD), the cards.
        let listFrame = layoutBands(top: y + spacesHeight, footerHeight: footerHeight + updateHeight + cardsHeight)
        footer.frame = NSRect(x: 0, y: belowFade.frame.minY - footerHeight, width: b.width, height: footerHeight)
        cardSlot.place(above: footer.frame.minY, width: b.width, slotHeight: updateHeight)
        footerCards?.frame = NSRect(x: 0, y: footer.frame.minY - updateHeight - cardsHeight, width: b.width, height: cardsHeight)
        layoutFooter(visibleSlots)
        layoutBack()
        placeSpaces(top: y, height: spacesHeight)
        edgeFade.frame = listFrame
        scrollView.tile()
        syncListSize()
        // Everything above may have moved under a still pointer (cx-3wu5).
        PointerHover.refresh(in: window)
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

    // The pointer over the sidebar reveals its chrome: `chromeHover`, set up in init.

    // MARK: Observation

    /// Everything the list renders. Emitting a value type lets the list
    /// skip reloads when an unrelated model property changes.
    private struct RenderState: Hashable, Sendable {
        var sections: [SidebarSection]
        var selection: Set<WorkspaceID>
        var selected: SidebarItem?
        var profiles: [SidebarProfile]
        var activeProfile: ProfileKey?
        var filter: String
        var layout: SidebarLayoutDocument
        var itemInfo: [LayoutItemID: SidebarItemInfo]
        var transientTopItems: [SidebarTransientItem]
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
        var showsBack: Bool
        var cards: SidebarBottomCards
    }

    private func observe() {
        let model = model
        observation = Task { [weak self] in
            for await state in Observations({
                RenderState(
                    sections: model.sections,
                    selection: model.selection,
                    selected: model.selectedItem,
                    profiles: model.profiles,
                    activeProfile: model.activeProfileID,
                    filter: model.filterText,
                    layout: model.layout,
                    itemInfo: model.resolvedItemInfo,
                    transientTopItems: model.transientTopItems,
                    collapsedSections: model.collapsedLayoutSections,
                    look: SidebarSectionTunables.currentLook,
                    drawsLines: Borders.drawsLines,
                    preferences: DesignSettings.shared.sidebarSections,
                    suppressedApps: model.suppressedApps,
                    metrics: .standard,
                    fontSize: Typography.body.pointSize,
                    titlebarHeight: Metrics.titlebarHeight,
                    showsBack: model.showsBack,
                    cards: SidebarBottomCards(update: model.updateCard, tip: model.tipCard)
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
            || lastState?.layout != state.layout || lastState?.itemInfo != state.itemInfo || lastState?.selected != state.selected
            || lastState?.transientTopItems != state.transientTopItems
            || lastState?.collapsedSections != state.collapsedSections || lastState?.look != state.look
            || lastState?.drawsLines != state.drawsLines || lastState?.preferences != state.preferences || lastState?.suppressedApps != state.suppressedApps
        let listChanged = lastState?.sections != state.sections || lastState?.selection != state.selection
            || lastState?.selected != state.selected || lastState?.filter != state.filter || chromeChanged || profileChanged
            || lastState?.preferences.showWorkspaceTabs != state.preferences.showWorkspaceTabs
            || lastState?.preferences.workspaceRow != state.preferences.workspaceRow
            || lastState?.preferences.groupsByComputer != state.preferences.groupsByComputer
        let previous = lastState?.sections
        model.applyListPreferences(state.preferences)
        // Minimal mode or an item's control changed: show or hide the chosen bands now.
        if lastState?.preferences.minimalMode != state.preferences.minimalMode || lastState?.itemInfo != state.itemInfo {
            setChromeRevealed(isChromeRevealed)
        }
        if listChanged {
            if profileChanged {
                switchSpace(from: lastState?.activeProfile, to: state.activeProfile, profiles: state.profiles, oldSections: previous ?? [])
            } else {
                list.reload(animated: Self.animatesReload(from: previous, to: state.sections))
            }
        }
        if lastState?.cards != state.cards { cardSlot.show(state.cards); needsLayout = true }
        if chromeChanged || profilesChanged || lastState?.showsBack != state.showsBack { needsLayout = true }
        lastState = state
    }

    /// Whether a sections change animates its rows. Provisional rows swap in place.
    static func animatesReload(from old: [SidebarSection]?, to new: [SidebarSection]) -> Bool {
        !((old ?? []) + new).contains(where: \.hasProvisionalRows)
    }
}

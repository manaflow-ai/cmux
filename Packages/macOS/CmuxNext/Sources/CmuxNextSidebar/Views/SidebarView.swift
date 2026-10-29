public import AppKit
public import CmuxNextDesign
public import CmuxNextResources
public import CmuxNextWakeups
import CmuxNextCompat
import CmuxNextIcons
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
// Keep implementation extensions in a separate checker namespace.
typealias SidebarViewComponents = SidebarView

public final class SidebarView: NSView {
    public let model: SidebarModel
    /// Height reserved at the top for the window's traffic lights (the
    /// toolbar buttons sit in this row, trailing). Nil follows
    /// `Metrics.titlebarHeight`, read at layout time.
    public var titlebarHeightOverride: CGFloat? { didSet { if titlebarHeightOverride != oldValue { needsLayout = true } } }
    /// Where the titlebar row's accessory may start: after the window's
    /// toolbar band (R68).
    public var titlebarLeadingReserve: CGFloat = 0 { didSet { if oldValue != titlebarLeadingReserve { needsLayout = true } } }
    /// False when the traffic lights are not over this header (a right
    /// sidebar, R109): the accessory then starts at the reserve alone.
    public var headerHasWindowControls = true { didSet { if oldValue != headerHasWindowControls { needsLayout = true } } }
    var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }
    let list: SidebarListView
    /// The list's scroll view: a ``ResponsiveSidebarScrollView`` with feature `responsiveScrolling`.
    let scrollView: SidebarScrollView
    let needsYouTray = SidebarNeedsYouTrayView() // the session tree's needs-you tray (SidebarView+NeedsYou)
    /// Coalesces the tray's recompute across a burst of row patches (status ticks).
    let needsYouRefresh = DemandTimer(owner: "sidebar.needs-you.refresh")
    private(set) lazy var spacePaging = SidebarSpacePaging(host: self)
    /// Hosts the list's scroll view and fades rows out at its top or bottom
    /// while more are hidden there.
    private(set) lazy var edgeFade = ScrollEdgeFadeView(scrollView: scrollView)  // built in setup (no IUO)
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
    // Built in the sections setup (no IUOs).
    lazy var aboveFade = ScrollEdgeFadeView(scrollView: aboveScroll)
    lazy var belowFade = ScrollEdgeFadeView(scrollView: belowScroll)
    /// The hairline between the top band and the list (quiet look). The
    /// footer has none (SIDEBAR-FOOTER-MINIMAL).
    let aboveLine = CALayer()
    let newButton = SidebarIconButton(icon: .actionAdd, label: Strings.newWorkspace)
    /// The footer's Search button, after the profile avatar (plans/cmux-next/sidebar-search.md):
    /// a press runs ``onSearch`` (the centered Search palette). `sidebar.showSearchButton` hides it.
    let searchButton = SidebarIconButton(icon: .search, pointSize: { Metrics.iconSize }, label: Strings.searchButton)
    /// Energy Saver's leaf at the footer's trailing end while the saver is on.
    let energyIndicator = SidebarEnergyIndicator()
    /// The Priority view, its titlebar bell and the bell's dot (SidebarView+Priority); nil `priority` hides all three.
    let priorityPanelView = SidebarPriorityPanelView(), priorityButton = SidebarIconButton(icon: .notification, label: Strings.priorityTitle)
    /// The quiet Update Available button (``showUpdateAvailable(_:)``).
    let updateAvailableButton = SidebarIconButton(symbol: "arrow.down.circle", label: "")
    let priorityBellDot = CALayer()
    var priority: SidebarPriorityPanel?
    /// Pointer over the sidebar (or a tab drag over it): titlebar buttons show.
    var isChromeRevealed = false
    /// The pointer over the sidebar now (cx-3wu5).
    private(set) var chromeHover: PointerHover?
    /// Bands minimal mode hides right now (the fade's target, R54).
    var minimalHiddenBands: (top: Bool, bottom: Bool) = (false, false)
    /// The hover chrome's last fade target; nil until the first reveal pass sets every piece.
    var appliedChromeReveal: SidebarChromeReveal?
    var accessories: [SidebarAccessorySlot: NSView] = [:]
    let footer = NSView()
    /// Edit mode's Add Items and Done (`SidebarView+EditItems`); nil out of edit mode.
    var editBar: SidebarEditBar?
    let updateCardView = SidebarUpdateCardView(), nowPlayingCardView = SidebarNowPlayingCardView(), updatedCardView = SidebarUpdatedCardHost(), noticeCardView = SidebarNoticeCardView()
    /// The card slot's room: the list's bottom edge springs on the render server when a card comes or goes.
    let cardSlotMotion = SidebarCardSlotMotion()
    /// Where the spaces dots sit (`sidebar.spacesPosition`, R109).
    public var spacesPosition: SpacesPosition = .bottom {
        didSet { if spacesPosition != oldValue { needsLayout = true } }
    }
    /// `sidebar.spacesVisibility` (cx-5k3r): Always keeps the strip shown with controls on hover too
    /// (``SidebarChromeReveal``); On Hover lets it fade with the other controls.
    public var spacesVisibility: SpacesVisibilityMode = .hover {
        didSet { if spacesVisibility != oldValue { setChromeRevealed(isChromeRevealed) } }
    }
    /// The list's draw (`render`), only while ``visibility`` renders (p06-scheduler.md rule 4).
    var observation: VisibleObservation<ObservationTrigger<RenderState>>?
    /// The list settings and the selection's reveal reach the model while the sidebar is hidden too (rule 3).
    var listSettingsWatch: ServiceObservation<ListSettings>?
    var selectionWatch: ServiceObservation<Set<WorkspaceID>>?
    /// The sidebar's place in the visibility tree: its window's node, hidden with the sidebar (a collapsed panel).
    let visibility = ViewVisibility("sidebar")
    /// The clip size the list was last fitted to from the clip's own resize push (`scrollGeometryDidChange`).
    var fittedClipSize: NSSize = .zero
    var lastState: RenderState?
    /// The sections the list showed at the last render (for the space slide and the provisional check).
    var lastSections: [SidebarSection] = []
    /// The bands' inputs changed since `updateBands` last ran (it runs in `layout`, only then).
    var bandsDirty = true
    /// The size the bands were laid out for (app sections take a share of the height).
    private var bandsSize: CGSize?
    /// App section contributions the bands showed at the last update (`releaseAppSections`).
    var shownAppContributions: Set<String> = []
    /// The `sidebar.*` settings this sidebar draws from (tests give their own).
    let design: DesignSettings
    /// The row feed of this sidebar's rows (the App injects it with feature `sidebarRowsNearViewport` on): only
    /// the rows the list draws on screen stay armed. Nil observes every row.
    public var rowFeed: SidebarRowFeed? {
        get { list.rowFeed }
        set {
            // The feed it leaves observes every row again.
            list.rowFeed?.follow(visibility: nil)
            list.rowFeed?.watch(drawn: nil, SidebarRowFeed.Viewport())
            list.rowFeed = newValue
            newValue?.follow(visibility: list.visibility)
            list.watchRows(layoutChanged: true)
        }
    }
    /// The app's sidebar document store (the App injects it): the list follows its events (`SidebarListView.docStore`).
    public var docStore: SidebarDocStore? {
        get { list.docStore }
        set { list.docStore = newValue }
    }
    /// - Parameters:
    ///   - model: What the sidebar shows.
    ///   - design: The `sidebar.*` settings it draws from.
    ///   - mainWork: The app's main-thread scheduler: the list draws through it while the sidebar shows.
    ///   - newRows: Told which rows each list reload lists (`create.workspace`); nil times nothing.
    ///   - responsiveScrolling: The list scrolls on AppKit's scrolling thread (feature `responsiveScrolling`).
    public init(model: SidebarModel, design: DesignSettings = .shared, mainWork: MainWorkScheduler,
                newRows: SidebarNewRowTimer? = nil, responsiveScrolling: Bool = false) {
        self.model = model
        self.design = design
        scrollView = responsiveScrolling ? ResponsiveSidebarScrollView() : SidebarScrollView()
        list = SidebarListView(model: model)
        list.newRows = newRows
        profileBar = ProfileBarView(model: model)
        super.init(frame: .zero)
        buildHierarchy()
        newButton.setAccessibilityIdentifier("cmux.sidebar.newWorkspace")
        list.reload(animated: false)
        observe(on: mainWork)
        // The chrome reveal follows the pointer and the sidebar's frame (cx-3wu5).
        chromeHover = PointerHover(self) { [weak self] hovering in self?.setChromeRevealed(hovering) }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            listSettingsWatch?.cancel()
            selectionWatch?.cancel()
        }
    }
    nonisolated override public var isFlipped: Bool { true }
    // R-hide: AppKit's moves, hides and unhides only reach the node; its observation follows the node.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }
    override public func viewDidHide() {
        super.viewDidHide()
        visibility.node.set(.hidden)
    }
    override public func viewDidUnhide() {
        super.viewDidUnhide()
        visibility.node.set(.visible)
    }
    // MARK: Public API
    /// An inline rename ended (commit or cancel). `byKeyboard` is true for
    /// Return, Escape or Tab; the host can return focus to its content.
    public var onRenameEnded: ((_ byKeyboard: Bool) -> Void)? {
        get { list.inlineRename.onEnded }
        set { list.inlineRename.onEnded = newValue }
    }
    /// The sidebar's chrome reveal changed (the window's title bar buttons follow).
    public var onChromeRevealChange: ((Bool) -> Void)?
    /// An optional view above the bottom card slot and the spaces dots (R114 slot; empty since the
    /// messages to the user moved to the shared notice card).
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
            // invalidate: another accessory (the guard above) takes the titlebar row.
            needsLayout = true
        }
    }

    /// Focuses the workspace list for keyboard navigation.
    public func focusList() {
        window?.makeFirstResponder(list)
    }

    /// Draws the sections apps contribute (`SectionContent.app`); the App
    /// injects one per window. Without it, app sections draw nothing.
    public var appSections: (any SidebarAppSectionProvider)? {
        didSet {
            // invalidate: an app section's view invalidated its intrinsic size (`AppSectionProvider`); the bands lay out again.
            appSections?.onContentChange = { [weak self] in self?.bandsDirty = true; self?.needsLayout = true }
            for region in bandRegions {
                region.appView = { [weak self] section in section.contribution.flatMap { self?.appSections?.makeView(for: $0) } }
            }
            bandsDirty = true
            // invalidate: another provider draws the app sections (set once per window).
            needsLayout = true
        }
    }

    /// The React update surfaces (cx-urd.61.2): the staged card's highlights
    /// popover and the "cmux Updated!" card. Set by the App; without them the
    /// popover does not open and the Updated card does not show.
    public var updateSurfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            // invalidate: the Updated card's page reports a new height (`UpdateSurfaceIsland.setHeight` on a change only).
            updatedCardView.onHeightChange = { [weak self] in self?.needsLayout = true }
            // Each page is made once its card shows.
            updateCardView.surfaces = updateSurfaces
            updatedCardView.surfaces = updateSurfaces
            // invalidate: other update surfaces (set once per window) may show another card.
            needsLayout = true
        }
    }

    /// The footer's Search button was pressed: the App opens Search (`palette.open`, scope
    /// `search`), the same centered palette as Cmd-P. Nil leaves the button doing nothing.
    public var onSearch: ((NSView) -> Void)?

    /// The profile menu the footer's profile control opens
    /// (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2); the App builds it from
    /// registry actions. Nil opens nothing.
    public var profileMenuProvider: (() -> NSMenu?)?
    /// The bottom band: footer slots, profile menu, spaces dots.
    private(set) lazy var footerBand = SidebarFooterBand(host: self)
    /// Opens the profile menu over the profile control; false when the App
    /// gave none. Without a visible control the menu opens at the pointer.
    @discardableResult
    public func showProfileMenu() -> Bool { footerBand.showProfileMenu(from: footerBand.profileControl?.view) }

    /// Right-click menu for a target. The App fills this from the action
    /// registry (menus are ordered action-ID lists per context); nil means
    /// no context menu.
    public var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { list.contextMenuProvider }
        set {
            list.contextMenuProvider = newValue
            // A row's more button is wired from the provider: live rows take the new one.
            for (key, view) in list.rowViews { list.wire(view, key: key) }
            profileBar.contextMenuProvider = newValue
            for region in bandRegions { region.contextMenuProvider = newValue }
        }
    }

    /// Starts inline rename of a workspace (the "rename workspace" action's sidebar entrypoint).
    public func beginRename(workspace id: WorkspaceID) { list.inlineRename.begin(.workspace(id)) }

    // MARK: Hierarchy

    private func buildHierarchy() {
        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }; newButton.menuProvider = { [weak self] in self?.list.contextMenuProvider?(.background) }
        newButton.alphaValue = chromeReveal(revealed: false).newButton
        addSubview(newButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // A gesture AppKit scrolls on its own thread never moves the list sideways, not even a bounce.
        if type(of: scrollView).isCompatibleWithResponsiveScrolling { scrollView.horizontalScrollElasticity = .none }
        // The shared thin scroller (the chat's): a 3 pt knob on no track, an
        // overlay that never narrows the list.
        SystemScrollers.followThin(scrollView)
        scrollView.automaticallyAdjustsContentInsets = false
        // The clip the edge fade and scroll fit share, in place before anything below holds the clip view;
        // it pushes its scrolls and resizes here too (`scrollGeometryDidChange`).
        ScrollGeometryClipView.install(in: scrollView).addClient(self)
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        // The app's one scroll-bar setting observer: it restyles the scroller (followThin), then the list fits the clip.
        SystemScrollers.observe(self) { [weak self] _ in self?.syncListSize() }
        spacePaging.attach(list: scrollView, dots: profileBar)
        addSubview(edgeFade)
        scrollFit = ScrollFitElasticity(scrollView: scrollView)
        buildBands(); buildNeedsYou()

        addSubview(footer)
        footer.addSubview(profileBar)
        searchButton.setAccessibilityIdentifier("cmux.sidebar.search")
        searchButton.onPress = { [weak self] in
            guard let self else { return }
            self.onSearch?(self.searchButton)
        }
        addSubview(searchButton)
        installEnergyIndicator()
        profileBar.alphaValue = spacesAlpha(revealed: isChromeRevealed)
        cardSlot.install(in: self)
        buildPriority()
        buildUpdateAvailable()
    }

    /// The list follows the visible clip (`SidebarListView.fitToClip`).
    func syncListSize() { list.fitToClip() }

    override public func layout() {
        super.layout()
        let b = bounds
        // Tokens are read here, never cached, so density changes apply live.
        // The list starts right under the titlebar row: no search field.
        let y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights at a stable frame.
        // Every control in the row centers on the traffic lights' line (the
        // tabs and the toolbar band do too); the row's middle without them.
        let button = SidebarStyle.toolbarButtonSize
        let rowMidY = window.flatMap(WindowTitlebar.trafficLightsFrame(in:)).map { convert($0, from: nil).midY } ?? titlebarHeight / 2
        newButton.frame = NSRect(x: b.width - Metrics.space3 - button, y: (rowMidY - button / 2).rounded(), width: button, height: button)
        let x = headerHasWindowControls ? max(Metrics.trafficLightInset, titlebarLeadingReserve) : titlebarLeadingReserve
        let titlebarButtonsMinX = layoutPriorityButton(before: newButton.frame)
        if let accessory = titlebarAccessory {
            let size = accessory.fittingSize
            let width = max(0, min(size.width, titlebarButtonsMinX - Metrics.space2 - x))
            accessory.frame = NSRect(x: x, y: (rowMidY - size.height / 2).rounded(), width: width, height: size.height)
            accessory.isHidden = width < size.height
        }

        // Footer slots.
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in
            accessories[slot].flatMap { view in view.isHidden ? nil : (slot, view) }
        }
        // A lone space switches nothing, so the footer keeps one control, the
        // profile control (Leo 2026-10-11: its mark and the History dot beside
        // it read as a duplicate switcher). Two or more spaces show the strip.
        // `sidebar.showSpaces` off (cx-wab7m) shows no strip, wherever it would sit.
        // `sidebar.noFade` (Lawrence 2026-10-26) hides the bottom profile and search bar and every edge fade.
        let noFade = design.sidebarSections.noFade
        let showsProfiles = ProfileBarLogic.isVisible(profileCount: model.profiles.count) && design.sidebarSections.showSpaces && !noFade
        profileBar.isHidden = !showsProfiles
        footerRegion.isHidden = noFade
        searchButton.isHidden = noFade
        for fade in [edgeFade, aboveFade, belowFade] { fade.fades = !noFade }
        // R109: the dots under the titlebar row, or in the footer.
        let spacesHeight: CGFloat = spacesPosition == .top && showsProfiles ? SidebarStyle.footerHeight : 0
        // Amendment 3: at the bottom the dots share the footer band's row
        // (after the profile control), so the dots row takes no height of
        // its own unless the band is empty.
        if bandsDirty || bandsSize != b.size {
            (bandsDirty, bandsSize) = (false, b.size)
            updateBands()
        }
        // `sidebar.noFade` hides the footer row, so the list takes its height.
        let footerHeight: CGFloat = noFade ? 0 : spacesPosition == .bottom && footerBand.dotsShareBandRow ? 0 : SidebarStyle.footerHeight
        // The list makes room for a card (and takes it back) on a render-server spring; the card
        // sits at its place (SidebarCardSlotMotion).
        let cardsHeight = attachFooterCards(), slotHeight = cardSlot.height
        let room = cardSlotMotion.room(toward: slotHeight, in: self), scrolledFrom = scrollView.contentView.bounds.minY
        // From the bottom up (R112/R114): the pinned footer section (the
        // profile control, then the dots), the band below the list, the
        // staged update card (UPDATE-CARD), the cards.
        let priorityHeight = layoutPriority(top: y + spacesHeight, width: b.width)
        let listFrame = layoutBands(top: y + spacesHeight + priorityHeight, footerHeight: footerHeight + room.list + cardsHeight)
        if !isChromeRevealed { belowFade.alphaValue = belowRegion.restAlpha(hiddenByMode: minimalHiddenBands.bottom) }
        footer.frame = NSRect(x: 0, y: belowFade.frame.minY - footerHeight, width: b.width, height: footerHeight)
        cardSlot.place(above: footer.frame.minY, width: b.width, slotHeight: slotHeight)
        footerCards?.frame = NSRect(x: 0, y: footer.frame.minY - slotHeight - cardsHeight, width: b.width, height: cardsHeight)
        footerBand.layoutFooter(visibleSlots)
        footerBand.placeSpaces(top: y, height: spacesHeight)
        footerBand.placeEnergy()
        edgeFade.frame = listFrame
        // Before the tile: the tray sets the scroll view's bottom inset.
        layoutNeedsYou(over: listFrame)
        scrollView.tile()
        syncListSize()
        let shownList = cardSlotMotion.didLayOut(room, listFrame: listFrame, edge: edgeFade, document: list,
                                                 scrolled: scrollView.contentView.bounds.minY - scrolledFrom, in: self)
        layoutEditBar(over: shownList)
        // Everything above may have moved under a still pointer (cx-3wu5).
        PointerHover.refresh(in: window)
    }

    // MARK: Titlebar row

    // The header row beside the traffic lights is titlebar: the window moves
    // it and runs the double-click action (`titlebarPress`, below).

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A bottom-band right-click no piece took opens the band's menu: Show for its hidden pieces (cx-wab7m).
    override public func menu(for event: NSEvent) -> NSMenu? {
        convert(event.locationInWindow, from: nil).y >= footer.frame.minY ? contextMenuProvider?(.footer) : super.menu(for: event)
    }

    // MARK: Hover reveal

    // The pointer over the sidebar reveals its chrome: `chromeHover`, set up in init.

}

// The header row beside the traffic lights is titlebar: a press there moves the
// window and a double-click runs the user's action, both from the window's one
// decision (`TitlebarDragPolicy`). The + button and the accessory take their own.
extension SidebarView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        let point = convert(windowPoint, from: nil)
        guard point.y < titlebarHeight else { return .staysPut }
        let controls = [newButton as NSView?, priorityButton, titlebarAccessory].compactMap { $0 }.filter { !$0.isHidden }
        return controls.contains { $0.frame.contains(point) } ? .staysPut : .movesWindow
    }
}

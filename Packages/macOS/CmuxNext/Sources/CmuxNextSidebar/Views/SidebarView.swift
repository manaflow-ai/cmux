public import AppKit
public import CmuxNextDesign
public import CmuxNextResources
import CmuxNextCompat
import CmuxNextIcons
import CmuxNextWakeups
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
    public var titlebarHeightOverride: CGFloat? { didSet { needsLayout = true } }
    /// Where the titlebar row's accessory may start: after the window's
    /// toolbar band (R68).
    public var titlebarLeadingReserve: CGFloat = 0 { didSet { if oldValue != titlebarLeadingReserve { titlebarReserveChanged() } } }
    /// False when the traffic lights are not over this header (a right
    /// sidebar, R109): the accessory then starts at the reserve alone.
    public var headerHasWindowControls = true { didSet { if oldValue != headerHasWindowControls { titlebarReserveChanged() } } }
    /// The window x the titlebar row's controls keep right of: the toolbar band's trailing edge on
    /// screen, which closes up with the sidebar's slide (`keepTitlebarControlsClearOfBand`).
    public var titlebarControlsFloor: CGFloat? { didSet { if oldValue != titlebarControlsFloor { keepTitlebarControlsClearOfBand() } } }
    /// How far the floor moves the row's controls right of where `layout()` placed them.
    var titlebarRowShift: CGFloat = 0
    /// Where the titlebar row's own controls may start: past the traffic lights and the toolbar
    /// band over a left sidebar, at the reserve alone otherwise.
    var titlebarLeadingX: CGFloat {
        headerHasWindowControls ? max(Metrics.trafficLightInset, titlebarLeadingReserve) : titlebarLeadingReserve
    }
    /// The narrowest width that fits the titlebar row: everything before ``titlebarLeadingX``,
    /// then the accessory as its square icon (an incognito window's mark never drops out), the
    /// Priority bell while it shows, the + (New Workspace) and its trailing inset. The options
    /// chevron hides first, so it does not count.
    var titlebarControlsWidth: CGFloat {
        let button = SidebarStyle.toolbarButtonSize
        let accessory = titlebarAccessory == nil ? 0 : button + Metrics.space2
        let priority = priorityButton.isHidden ? 0 : button + Metrics.space1
        return titlebarLeadingX + accessory + priority + button + SidebarStyle.titlebarPlusTrailingInset
    }

    /// The reserve or the row's buttons changed: lay the row out again and give the model the
    /// width the row now needs.
    func titlebarReserveChanged() {
        needsLayout = true
        model.titlebarControlsWidth = titlebarControlsWidth
    }
    var titlebarHeight: CGFloat { titlebarHeightOverride ?? Metrics.titlebarHeight }
    let list: SidebarListView
    let scrollView = SidebarScrollView()
    let needsYouTray = SidebarNeedsYouTrayView() // the session tree's needs-you tray (SidebarView+NeedsYou)
    /// Coalesces the tray's recompute across a burst of row patches (status ticks).
    let needsYouRefresh = DemandTimer(owner: "sidebar.needs-you.refresh")
    private(set) lazy var spacePaging = SidebarSpacePaging(host: self)
    /// Hosts the list's scroll view and fades rows out at its top or bottom
    /// while more are hidden there.
    lazy var edgeFade = ScrollEdgeFadeView(scrollView: scrollView)  // built in setup (no IUO)
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
    /// The +'s menu segment, right of the + as one split button (Lawrence 2026-10-30: "the dropdown
    /// on left of plus is ugly"): the + itself remains a one-click workspace action.
    let newWorkspaceOptionsButton = TitlebarBandButton(symbol: "chevron.down")
    /// The footer's Search button, after the profile avatar (plans/cmux-next/sidebar-search.md):
    /// a press runs ``onSearch`` (the centered Search palette). `sidebar.showSearchButton` hides it.
    let searchButton = SidebarIconButton(icon: .search, pointSize: { Metrics.iconSize }, label: Strings.searchButton)
    /// The Priority view, its titlebar bell and the bell's dot (SidebarView+Priority); nil `priority` hides all three.
    let priorityPanelView = SidebarPriorityPanelView(), priorityButton = SidebarIconButton(icon: .notification, label: Strings.priorityTitle)
    /// The quiet Update Available button (``showUpdateAvailable(_:)``).
    let updateAvailableButton = SidebarIconButton(symbol: "arrow.down.circle", label: "")
    /// Swift live mode's mark (LiveModeBadgeView), right of the profile avatar on the footer line
    /// (Leo 2026-11-06: "at the bottom just to the right of the profile circle in the sidebar").
    /// Nil while this app is not the live code build.
    public var liveModeBadge: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            liveModeBadge.map { addSubview($0) }
            needsLayout = true
        }
    }
    /// App health's dot and line on the footer line after the avatar (design/app-health.md); it shows and
    /// hides itself and asks for a layout. It never fades with the footer.
    public var healthIndicator: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            healthIndicator.map { addSubview($0) }
            needsLayout = true
        }
    }
    let priorityBellDot = CALayer()
    var priority: SidebarPriorityPanel?
    /// Pointer over the sidebar (or a tab drag over it): titlebar buttons show.
    var isChromeRevealed = false
    /// Menus opened from the hover-revealed titlebar controls that are open now: the chrome
    /// stays revealed until they close (``chromeMenuOpenChanged(_:)``).
    var chromeMenuHolds = 0
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
    /// The card slot's height as the list lays out: springs when a card comes or goes.
    let cardSlotMotion = SidebarCardSlotMotion()
    /// The room the Updated card takes at the list's top once it is dragged there, on the same spring.
    let topCardMotion = SidebarCardSlotMotion()
    /// Where the spaces dots sit (`sidebar.spacesPosition`, R109).
    public var spacesPosition: SpacesPosition = .bottom {
        didSet { if spacesPosition != oldValue { needsLayout = true } }
    }
    /// `sidebar.spacesVisibility` (cx-5k3r): Always keeps the strip shown with controls on hover too
    /// (``SidebarChromeReveal``); On Hover lets it fade with the other controls.
    public var spacesVisibility: SpacesVisibilityMode = .hover {
        didSet { if spacesVisibility != oldValue { setChromeRevealed(isChromeRevealed) } }
    }
    var observation: Task<Void, Never>?
    private var clipObservers: [any NSObjectProtocol] = []
    var lastState: RenderState?
    /// A `renderInFrame` draw is queued for this turn's frame.
    var renderQueued = false
    /// The sections the list showed at the last render (for the provisional check).
    var lastSections: [SidebarSection] = []
    /// The bands' inputs changed since `updateBands` last ran (it runs in `layout`, only then).
    var bandsDirty = true
    /// The size the bands were laid out for (app sections take a share of the height).
    private var bandsSize: CGSize?
    /// App section contributions the bands showed at the last update (`releaseAppSections`).
    var shownAppContributions: Set<String> = []
    /// The `sidebar.*` settings this sidebar draws from (tests give their own).
    let design: DesignSettings
    public init(model: SidebarModel, design: DesignSettings = .shared) {
        self.model = model
        self.design = design
        list = SidebarListView(model: model)
        list.keepsSpareRow = true // a new workspace's row takes a view made before its key (SidebarListView+SpareRow)
        profileBar = ProfileBarView(model: model)
        super.init(frame: .zero)
        buildHierarchy()
        list.hoverOccluded = { [weak self] point in self?.updatedCardView.covers(windowPoint: point) == true }
        newButton.setAccessibilityIdentifier("cmux.sidebar.newWorkspace")
        // The tab row's New Tab + (Leo 2026-11-07: one size class for both, in the middle of the two).
        newButton.drawsAddGlyph = true
        newWorkspaceOptionsButton.setAccessibilityLabel(Strings.newWorkspaceOptions)
        newWorkspaceOptionsButton.setAccessibilityIdentifier("cmux.sidebar.newWorkspace.options")
        list.reload(animated: false)
        observe()
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
            for token in clipObservers { NotificationCenter.default.removeObserver(token) }
        }
    }
    nonisolated override public var isFlipped: Bool { true }
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
            titlebarReserveChanged()
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
            appSections?.onContentChange = { [weak self] in self?.bandsDirty = true; self?.needsLayout = true }
            for region in bandRegions {
                region.appView = { [weak self] section in section.contribution.flatMap { self?.appSections?.makeView(for: $0) } }
            }
            bandsDirty = true
            needsLayout = true
        }
    }

    /// The React update surfaces (cx-urd.61.2): the staged card's highlights
    /// popover and the "cmux Updated!" card. Set by the App; without them the
    /// popover does not open and the Updated card does not show.
    public var updateSurfaces: (any SidebarUpdateSurfaces)? {
        didSet {
            updatedCardView.onHeightChange = { [weak self] in self?.needsLayout = true }
            // Each page is made once its card shows.
            updateCardView.surfaces = updateSurfaces
            updatedCardView.surfaces = updateSurfaces
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

    /// Makes a row of a workspace row's drive indicator menu: Go to the agent's tab, or Stop what it
    /// drives, titled `title`. The App fills this from the action registry, so the row runs the same
    /// action as the palette, the File menu and the CLI; the sidebar never runs its own handler. Nil,
    /// or nil for a row, leaves the row out.
    public var driveMenuItem: ((WorkspaceID, SidebarDriveCommand, _ title: String) -> NSMenuItem?)? {
        get { list.driveMenuItem }
        set {
            list.driveMenuItem = newValue
            for (key, view) in list.rowViews { list.wire(view, key: key) }
        }
    }

    /// Starts inline rename of a workspace (the "rename workspace" action's sidebar entrypoint).
    public func beginRename(workspace id: WorkspaceID) { list.inlineRename.begin(.workspace(id)) }

    // MARK: Hierarchy

    private func buildHierarchy() {
        newButton.onPress = { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) }
        newButton.menuProvider = { [weak self] in self?.list.contextMenuProvider?(.background) }
        newWorkspaceOptionsButton.longPressOpensMenu = false
        newWorkspaceOptionsButton.symbolPointSize = { SidebarStyle.toolbarMenuChevronPointSize }
        // The chooser opens under the whole split button, from the +'s leading edge, as a
        // toolbar menu item's does.
        newWorkspaceOptionsButton.presentMenu = { [weak self] menu, button in
            let anchor: NSView = self?.newButton ?? button
            menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: anchor, gap: Metrics.space1), in: anchor)
        }
        newWorkspaceOptionsButton.pressMenu = { [weak self] in self?.list.contextMenuProvider?(.background) }
        newWorkspaceOptionsButton.target = self
        newWorkspaceOptionsButton.action = #selector(openNewWorkspaceOptions)
        newButton.onMenuOpenChange = { [weak self] open in self?.chromeMenuOpenChanged(open) }
        newWorkspaceOptionsButton.onMenuOpenChange = { [weak self] open in self?.chromeMenuOpenChanged(open) }
        newButton.alphaValue = chromeReveal(revealed: false).newButton
        newWorkspaceOptionsButton.alphaValue = newButton.alphaValue
        addSubview(newButton)
        addSubview(newWorkspaceOptionsButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // The shared thin scroller (the chat's): a 3 pt knob on no track, an
        // overlay that never narrows the list.
        SystemScrollers.followThin(scrollView)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        clipObservers = [ // queue: .main: inline for a post on main; a selector into this view trapped off main
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.clipBoundsChanged() } }, // main-proof: observer on queue: .main
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.syncListSize() } }, // main-proof: observer on queue: .main
            NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.scrollerStyleChanged() } }, // main-proof: observer on queue: .main
        ]
        spacePaging.attach(list: scrollView, dots: profileBar)
        addSubview(edgeFade)
        // A stuck project header draws its own fade under it: the list's top fade holds off while one is stuck.
        list.onStuckHeaderChange = { [weak self] stuck in self?.edgeFade.holdsTopEdge = stuck }
        scrollFit = ScrollFitElasticity(scrollView: scrollView)
        buildBands(); buildNeedsYou()

        addSubview(footer)
        footer.addSubview(profileBar)
        // A switcher menu keeps the strip revealed while it is open, as the + menu does.
        profileBar.onMenuOpenChange = { [weak self] open in self?.chromeMenuOpenChanged(open) }
        searchButton.setAccessibilityIdentifier("cmux.sidebar.search")
        searchButton.onPress = { [weak self] in
            guard let self else { return }
            self.onSearch?(self.searchButton)
        }
        addSubview(searchButton)
        profileBar.alphaValue = spacesAlpha(revealed: isChromeRevealed)
        cardSlot.install(in: self)
        buildPriority()
        buildUpdateAvailable()
    }

    /// The + and its chevron segment share one rounded outline: their hover and pressed fills
    /// keep only the pair's outer corners while the chevron shows.
    private func joinSplitButtonCorners(_ joined: Bool) {
        let all: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        newButton.layer?.maskedCorners = joined ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : all
        newWorkspaceOptionsButton.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }

    @objc private func openNewWorkspaceOptions() {
        newWorkspaceOptionsButton.performPressMenu()
    }

    private func clipBoundsChanged() {
        list.realizeVisibleRows()
        // The list updates row hover as rows move. A window-wide refresh here
        // rescans every chrome target on every scroll tick and adds no state
        // change for the sidebar's fixed chrome.
    }

    private func scrollerStyleChanged() {
        scrollView.scrollerStyle = SystemScrollers.nativeStyle
        syncListSize()
    }

    /// The list follows the visible clip (`SidebarListView.fitToClip`).
    private func syncListSize() { list.fitToClip() }

    override public func layout() { // perf-hot: 1ms window-resize-step
        super.layout()
        let b = bounds
        // Tokens are read here, never cached, so density changes apply live.
        // The list starts right under the titlebar row: no search field.
        let y = titlebarHeight

        // Titlebar row: buttons trail the traffic lights at a stable frame.
        // Every control in the row centers on the traffic lights' line (the
        // tabs and the toolbar band do too); the row's middle without them.
        let button = SidebarStyle.toolbarButtonSize
        let rowMidY = window.flatMap(Self.titlebarRowMidY(in:)).map { convert(CGPoint(x: 0, y: $0), from: nil).y } ?? titlebarHeight / 2
        let x = titlebarLeadingX
        // On the device pixel grid, not whole points: the top row's line can sit on a half point (#38054).
        let pixels = max(window?.backingScaleFactor ?? 2, 1)
        let buttonY = ((rowMidY - button / 2) * pixels).rounded() / pixels
        let trailing = b.width - Metrics.space3
        // The + and its chooser chevron are one split button: the + first, the narrow chevron
        // segment right after it, touching. The chevron is the optional extra (the +'s right-click
        // menu holds the same chooser): on a sidebar too narrow for it and the Priority button
        // beside the +, it hides before either one reaches the leading reserve (the toolbar band
        // sits above it there and takes the clicks), and the + takes the trailing slot alone.
        let segment = SidebarStyle.toolbarMenuSegmentWidth
        // The accessory's square icon (an incognito window's mark) keeps its room ahead of the chevron.
        let accessoryRoom = titlebarAccessory == nil ? 0 : button + Metrics.space2
        let pairMinX = trailing - segment - button - (priorityButton.isHidden ? 0 : Metrics.space1 + button) - accessoryRoom
        // `sidebar.showNewWorkspaceChooser` (off by default, Lawrence 2026-10-30: "by default i dont want to have
        // workspace titlebar dropdowns at all"): without it the + stands alone and its right-click menu holds the chooser.
        let showsChevron = design.sidebarSections.showNewWorkspaceChooser && pairMinX >= x
        newWorkspaceOptionsButton.isHidden = !showsChevron
        // The + alone centers on the trailing column, the rows' status marks' and footer Search's one x (Leo
        // 2026-11-07: "the top of the sidebar with the subsequent elements below (workspaces and their notification
        // symbols, then the search icon)"); with its chooser segment the pair keeps the row's trailing inset.
        let plusX = showsChevron ? trailing - button - segment
            : SidebarStyle.trailingColumnFrame(sidebarWidth: b.width, centerY: rowMidY, side: button).minX
        newButton.frame = NSRect(x: plusX, y: buttonY, width: button, height: button)
        newWorkspaceOptionsButton.frame = NSRect(x: newButton.frame.maxX, y: buttonY, width: segment, height: button)
        joinSplitButtonCorners(showsChevron)
        let titlebarButtonsMinX = layoutPriorityButton(before: newButton.frame)
        if let accessory = titlebarAccessory {
            accessory.frame = Self.titlebarAccessoryFrame(fitting: accessory.fittingSize, x: x,
                                                          room: titlebarButtonsMinX - Metrics.space2 - x,
                                                          button: button, buttonY: buttonY, rowMidY: rowMidY)
            accessory.isHidden = accessory.frame.isEmpty
        }
        // The frames above are the row at rest; the band's edge on screen may hold it further right.
        titlebarRowShift = 0
        keepTitlebarControlsClearOfBand()

        // Footer slots.
        let visibleSlots = SidebarAccessorySlot.allCases.compactMap { slot in
            accessories[slot].flatMap { view in view.isHidden ? nil : (slot, view) }
        }
        // Keep the profile mark visible even for one space: it identifies the
        // current space and gives a narrow footer a hover target for +.
        // `sidebar.showSpaces` off (cx-wab7m) shows no strip, wherever it would sit.
        // `sidebar.noFade` (Lawrence 2026-10-26) hides the bottom profile and search bar and every edge fade.
        let noFade = design.sidebarSections.noFade
        let spaceCount = model.profiles.count
        let showsProfiles = ProfileBarLogic.isVisible(profileCount: spaceCount) && (spacesPosition == .bottom || spaceCount > 1)
            && design.sidebarSections.showSpaces && !noFade
        profileBar.isHidden = !showsProfiles
        footerRegion.isHidden = noFade
        searchButton.isHidden = noFade
        liveModeBadge?.isHidden = noFade
        for fade in [edgeFade, aboveFade, belowFade] { fade.fades = !noFade }
        // R109: the dots under the titlebar row, or in the footer.
        let spacesHeight: CGFloat = spacesPosition == .top && showsProfiles ? SidebarStyle.footerHeight : 0
        // Amendment 3: at the bottom the dots share the footer band's row
        // (after the profile control), so the dots row takes no height of
        // its own unless the band is empty.
        // What the footer's space switcher shows changed (`render` sets `bandsDirty` for the spaces, the current space,
        // the sidebar's metrics, the switcher's own tokens and the app sections): a layout for a new size only does not
        // make the switcher again (a window resize step).
        let spacesChanged = bandsDirty
        if bandsDirty || bandsSize != b.size {
            (bandsDirty, bandsSize) = (false, b.size)
            updateBands()
        }
        // `sidebar.noFade` hides the footer row, so the list takes its height.
        let footerHeight: CGFloat = noFade ? 0 : (footerBand.needsDedicatedSearchRow ||
            !(spacesPosition == .bottom && footerBand.dotsShareBandRow) ? SidebarStyle.footerHeight : 0)
        // The list makes room for a card (and takes it back) on a spring; the card sits at its place.
        let cardsHeight = attachFooterCards(), slotHeight = cardSlot.height(width: b.width)
        // The Updated card after a relaunch takes its room in the frame it shows (Leo 2026-11-04).
        let landsAtOnce = cardSlot.updatedLandsAtOnce
        // The Updated card dragged to the top takes its room there; the bottom slot's closes (Leo 2026-11-07).
        let atTop = cardSlot.updatedAtTop
        let updateHeight = cardSlotMotion.height(toward: atTop ? 0 : slotHeight, in: self, snaps: landsAtOnce)
        let topCardHeight = topCardMotion.height(toward: atTop ? slotHeight : 0, in: self, snaps: landsAtOnce)
        if landsAtOnce { updatedCardView.landed() }
        // From the bottom up (R112/R114): the pinned footer section (the
        // profile control, then the dots), the band below the list, the
        // staged update card (UPDATE-CARD), the cards.
        let priorityHeight = layoutPriority(top: y + spacesHeight, width: b.width)
        let listTop = y + spacesHeight + priorityHeight
        let listFrame = layoutBands(top: listTop + topCardHeight, footerHeight: footerHeight + updateHeight + cardsHeight)
        if !isChromeRevealed { belowFade.alphaValue = belowRegion.restAlpha(hiddenByMode: minimalHiddenBands.bottom) }
        footer.frame = NSRect(x: 0, y: belowFade.frame.minY - footerHeight, width: b.width, height: footerHeight)
        cardSlot.place(above: footer.frame.minY, top: listTop, width: b.width, slotHeight: slotHeight, in: self)
        footerCards?.frame = NSRect(x: 0, y: footer.frame.minY - updateHeight - cardsHeight, width: b.width, height: cardsHeight)
        footerBand.layoutFooter(visibleSlots)
        footerBand.placeSpaces(top: y, height: spacesHeight, modelChanged: spacesChanged)
        edgeFade.frame = listFrame
        clipBandsUnderTrafficLights()
        layoutEditBar(over: listFrame)
        layoutNeedsYou(over: listFrame)
        scrollView.tile()
        syncListSize()
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
        let controls = [newButton as NSView?, newWorkspaceOptionsButton, priorityButton, titlebarAccessory].compactMap { $0 }.filter { !$0.isHidden }
        return controls.contains { $0.frame.contains(point) } ? .staysPut : .movesWindow
    }
}

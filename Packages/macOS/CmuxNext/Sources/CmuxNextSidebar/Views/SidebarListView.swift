import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
/// Scrollable document view that renders the sidebar tree.
///
/// Why a custom layer-backed list instead of NSOutlineView: the drag we want
/// (lifted live row, springs on every sibling, a gap that opens in the target
/// container, group-header highlight, a pill that glides between rows) needs
/// per-row frame animation in one CA transaction. NSOutlineView's drag gap is
/// a fixed feedback style, its row animations are insert/remove only, and its
/// drag image is a static snapshot. Here layout is a pure function
/// (`SidebarLayout`), so every change is "compute new frames, animate to them",
/// and only rows near the viewport get views (see `realizationRect`).
// Keep implementation extensions in a separate checker namespace.
typealias SidebarListViewComponents = SidebarListView

final class SidebarListView: NSView {
    let model: SidebarModel
    var displayed = SidebarLayout.empty
    /// Each layout `apply` draws, in order (a test records every frame the list shows, a one-hop glitch too).
    var onApply: ((SidebarLayout) -> Void)?
    var rowViews: [SidebarRowKey: SidebarRowView] = [:]
    var workspaces: [WorkspaceID: SidebarWorkspace] = [:]
    var groups: [GroupID: SidebarGroup] = [:]
    /// Each group and the groups under it, in document order (`reload`): a section lists a subgroup
    /// after its parent, not inside it, so a parent's card reads its members through this.
    var groupSubtrees: [GroupID: [GroupID]] = [:]
    /// The rails before the nested-groups prototype (a capture's "before"); off draws the subtree rails.
    var legacyNestedRails = false
    var sections: [SectionID: SidebarSection] = [:]
    /// The sections the list draws in their own arrangement (tiles, a grid, a line, item rows) on the sidebar document.
    var blocks: SidebarListBlocks? {
        // A held drag hit-tests a geometry built at its begin: new blocks rebuild it at the next move.
        didSet { if blocks != oldValue { drag?.docGeometry = nil } }
    }
    /// The selected top item, drawn active in its block (`SidebarRegionView.activeItem`): a selection
    /// change repaints the old and new item only, with no list reload (perf-speed-of-light I6).
    var activeTopItem: LayoutItemID? {
        didSet {
            guard oldValue != activeTopItem else { return }
            for view in rowViews.values { (view as? SidebarBlockRowView)?.region.activeItem = activeTopItem }
        }
    }
    /// The multi-selection, drawn on the blocks' pinned workspace tiles (`SidebarRegionView.selectedWorkspaces`).
    var selectedWorkspaces: Set<WorkspaceID> = [] {
        didSet {
            guard oldValue != selectedWorkspaces else { return }
            for view in rowViews.values { (view as? SidebarBlockRowView)?.region.selectedWorkspaces = selectedWorkspaces }
        }
    }
    /// A dropped drag whose move is on the way: the list keeps showing its drop (the rows or tile at the
    /// slot, the source closed) until the model or the blocks change, so the drop settles with no fly-back
    /// and no pop when the move lands; a refusal lets it go and the rows spring back.
    var settling: SidebarSettlingDrop?
    /// The drag whose look the list shows: the running one, else the settling one.
    var shownDrag: Drag? { drag ?? settling?.drag }
    /// The drag whose card is flying to its slot (the motion probe's card after the settle ended).
    var landing: Drag?
    /// The apply running now adopts a drag's look (a drop, a refusal, a settle's end, a model change
    /// under a held drag): rows spring from where they are on the drag's one additive spring, new rows
    /// appear in their slot with no opening, so frames the drag already shows move nothing.
    var springsRows = false
    /// Counts the row moves `RowMotion` starts: a move's end lands the rows only when no newer move runs.
    var rowMoves = 0
    /// Rows an adopting apply took out of `rowViews` that still fade on screen (sampled by the motion probe).
    var fadingRows: [ObjectIdentifier: SidebarRowView] = [:]
    /// Wires a new block's region as the sidebar wires its bands (activation, menus, app views).
    var configureBlockRegion: ((SidebarRegionView) -> Void)?
    /// The workspaces pinned above the list (the band), in drawn order: a Shift range starts there (`selectionOrder`).
    var leadingSelectionOrder: () -> [WorkspaceID] = { [] }
    /// Listed document items (link, tab, app rows) by item id.
    var listItems: [String: SidebarListItem] = [:]
    /// The drag gap CALayer, under the rows.
    let decorations = SidebarDecorationView()
    /// Open groups' members' lines, under the rows, moving with them.
    let groupLineViews = SidebarGroupLineViews()
    /// The session tree's chat history (Pinned and Earlier), in the gaps the layout leaves for them.
    let chatHistory = SidebarChatHistoryViews()
    /// Recycled row views by class; only rows near the viewport have views.
    var rowPool = SidebarRowViewPool()
    var hoveredKey: SidebarRowKey?
    /// True while a scroll moves the hover to the row under a still pointer: that row's hover
    /// shows at once instead of fading, so a scroll does not start a fade on every row it passes.
    var hoverFollowsScroll = false
    /// Bulk projection applies update many rows before the next frame. Hover
    /// paint remains valid, but marquee/layout work must wait for that frame.
    var suppressHoverEffects = false
    /// Workspace hover card (title, cwd, CPU and memory).
    let hoverCard = WorkspaceHoverCardController()
    var press: Press?
    let middleClick = SidebarMiddleClick()
    /// A click on a group's name waits out the double-click interval before it folds.
    let groupNameClick = SidebarGroupNameClick()
    var drag: Drag?
    /// Rows kept invisible while a lifted view stands in for them.
    var suppressed: Set<SidebarRowKey> = []
    var openingRows: [SidebarRowKey: SidebarRowOpening] = [:] // Rows still opening their slot (`SidebarRowOpening`).
    /// The model's sections at the last `apply`, so an apply can tell a workspace new to the model from one listed again
    /// (`opensOnlyNewWorkspaces`).
    var appliedSections: [SidebarSection] = []
    /// Whether the pointer is over the list's visible rows now (`showModelChange` holds a change then).
    /// Tests inject an answer; the default asks the window where its pointer is.
    var pointerIsOverList: @MainActor (SidebarListView) -> Bool = { $0.pointerIsOverVisibleRows }
    /// A model change held while the pointer was over the list; it shows when the pointer leaves (`releaseHeldModelChange`).
    var holdsModelChange = false
    /// Row patches held while a drag, its settle or its card's landing runs (`SidebarRowHold`).
    var rowHold = SidebarRowHold()
    /// Workspaces a pin drop took to the band: out of the list until its card lands (cx-odqn).
    var leaving: Set<WorkspaceID> = []
    /// The "Done (N)" rows the person opened (`SidebarLayout+DoneFold`): view state, kept for this list only.
    var openDoneFolds: Set<SidebarDoneFoldID> = []
    /// The lists whose "Show N more" row the person opened: view state, kept for this list only.
    var openShowMore: Set<SidebarDoneFoldID> = []
    /// Inline rename of a workspace row (a group's name is edited in `groupEditor`).
    let inlineRename = SidebarInlineRename()
    /// The group editor bubble (SidebarListView+GroupEditor) and its App-filled rows.
    let groupEditor = SidebarGroupEditor()
    var groupEditorItems: ((GroupID) -> [[SidebarGroupEditorItem]])?
    var onGroupEditorItem: ((GroupID, String) -> Void)?
    var groupEditing: SidebarGroupEditing { SidebarGroupEditing(list: self) }
    /// Drag autoscroll frames from the window's FrameScheduler.
    lazy var autoscroll = SidebarDragAutoscroll(list: self)
    /// Per-display-frame samples for the drag feel proof (`debug.sidebar_rows` motion).
    lazy var motionProbe = SidebarMotionProbe(list: self)
    /// Main-thread milliseconds of the last drag move (`SidebarMotionFrame.dragWorkMs`).
    var lastDragWorkMs: Double = 0
    var external: ExternalDrag?
    /// The selection the last reload or selection patch revealed (`selectionRevealKey`; close-focus.md: reveal on change).
    var revealedActive: SidebarRowKey?
    /// The row that stands for the selection (`SidebarLayout.selectedRowKey`).
    internal(set) var selectedRowKey: SidebarRowKey?
    /// The anchor step moves the offset; rows wait for the new layout.
    var isShiftingViewport = false
    /// The rect a list outside a scroll view shows (a space page, `SidebarSpacePaging`): rows are
    /// realized for it only. Nil realizes the list's bounds, every row (space-switch-fast: a page
    /// made every row view of its space, so a switch cost grew with the space's workspaces).
    var pageViewport: NSRect?
    /// Offered a row drag whose pointer left the sidebar sideways (another
    /// window, outside every window); true takes it over.
    var onDragHandoff: ((SidebarDragHandoff) -> Bool)?
    /// Whether a dragged document item is removed when dropped beside the sidebar, and its removal (`holdsDragOut`).
    var removesOnDragOut: ((String) -> Bool)?
    var onDragOutRemove: ((String) -> Void)?
    /// Hover time before an external tab drag over a row selects it.
    var springLoadDelay: Duration = .milliseconds(500)
    /// Clock for the spring-load delay; tests inject a manual clock.
    var springLoadClock: any Clock<Duration> = ContinuousClock()
    /// The group header that holds keyboard focus (arrow keys stop on
    /// headers; focus is not selection). Nil when a workspace has it.
    var focusedGroup: GroupID?
    /// The disclosure with keyboard focus; focus never changes workspace selection.
    var focusedFold: SidebarRowKey?
    /// The keyboard moved focus to `focusedGroup`, so its header draws the
    /// ring (a click focuses without one). A header view made later, by
    /// reuse or scrolling, draws it from this (SidebarListView+Reuse).
    var showsFocusRing = false
    /// Builds the right-click menu for a target (filled by the App from the
    /// action registry). Nil means no context menu.
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    /// Opens a menu a row's button asked for at `anchor` (the button's frame in `view`):
    /// under the button, on the anchor's edge. Tests inject a recorder (popUp tracks modally).
    var menuPresenter: (NSMenu, PopupAnchor, NSView) -> Void = { menu, anchor, view in
        _ = menu.popUp(positioning: nil, at: anchor.menuOrigin(size: menu.size, flipped: view.isFlipped), in: view)
    }
    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        decorations.autoresizingMask = [.width, .height]
        addSubview(decorations)
        setAccessibilityRole(.outline)
        setAccessibilityLabel(Strings.sidebarLabel)
        hoverCard.list = self
        inlineRename.list = self
        groupEditing.wire()
        // A row content change configures its one row (SidebarRowIndex), never reloads the list.
        model.onRowsPatched = { [weak self] rows in self?.patchRows(rows) }
        // A group's fold splices that group's rows (SidebarListView+Fold), never reloads the list.
        model.onGroupFolded = { [weak self] group in self?.foldGroup(group) }
        // A close's successor is the next row drawn here (FocusAfterClose.workspace).
        model.drawnWorkspaceOrder = { [weak self] in self?.visibleWorkspaceOrder ?? [] }
        model.drawnSelectionOrder = { [weak self] in self?.selectionOrder ?? [] }
        // A refused change: a settling drop lets go and the rows spring back.
        // A no-op drop settles the same way (nothing will change the model).
        for name in [SidebarDocStore.refusedNotification, SidebarDocStore.settledNotification] {
            settleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let key = note.userInfo?["key"] as? String
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    // Only this list's drop: its key, or a refusal inside its own drop call (no key recorded yet).
                    guard let self, let settling = self.settling, settling.key == nil || settling.key == key else { return }
                    self.settling = nil
                    // The rows spring back from the drop's look and the card flies back to its source slot.
                    self.reload(animated: true, adopt: true)
                    self.land(settling.drag, then: settling.then)
                }
            })
        }
        // A favicon arrived: the link rows draw it (one configure per realized link row).
        faviconObserver = NotificationCenter.default.addObserver(forName: SidebarModel.itemFaviconsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                // The realized link rows only: a launch's favicons arrive one by one, and each visited every row.
                for (key, view) in self.rowViews {
                    guard case .item = key, let row = self.displayed.row(for: key) else { continue }
                    self.configure(view, row: row, animated: false)
                }
            }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            // Leave the frame client alone: an active one goes idle on its next tick
            // once self is gone (touching the lazy property here would create one).
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            if let faviconObserver { NotificationCenter.default.removeObserver(faviconObserver) }
            for observer in settleObservers + focusObservers { NotificationCenter.default.removeObserver(observer) }
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        }
    }
    // MARK: - Window occlusion
    private var observedWindow: NSWindow?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var faviconObserver: (any NSObjectProtocol)?
    private var settleObservers: [any NSObjectProtocol] = []
    private var focusObservers: [any NSObjectProtocol] = []
    /// The app's left presses and releases while this list is in a window (`observePointerEnds`).
    private var pointerMonitor: Any?
    /// Whether the left button is held now (`pointerWindowLostKey`). Tests inject an answer.
    var leftButtonIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Off screen a card's landing never completes: it ends now (its held rows show, the reloads stop adopting).
        if newWindow == nil, let landing { finishLand(landing, then: landing.landingThen) }
        releaseRowHold() // a settle still running keeps the rows held until it ends (`reload`)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A move to another window (or none) ends this list's card only.
        hoverCards.unregister(hoverCard)
        if window != nil { hoverCards.register(hoverCard) }
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let occlusionObserver { center.removeObserver(occlusionObserver) }
        observedWindow = window
        // A gesture ends when its window or the app loses focus (`pointerFocusLost`). Off screen no card can land:
        // a drag ends in place (`abandonDrag`, its rows shown again).
        for observer in focusObservers { center.removeObserver(observer) }
        focusObservers = window == nil ? [] : observeFocusLoss(of: window)
        // A press whose release never came here ends at the app's next press, or after a release that went to
        // another window (`pointerEventSeen`).
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = window == nil ? nil : observePointerEnds()
        if window == nil {
            if let drag { abandonDrag(drag) }
            press = nil
        }
        // queue: .main (inline for AppKit's post on main); a selector into this main-actor view trapped off main.
        occlusionObserver = window.map { center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowOcclusionChanged() } // main-proof: observer on queue: .main
        } }
        // The rows read the window when they moved in; the list's own reading starts them all from
        // the same state, not each from whatever its window said a moment earlier.
        if window != nil { windowOcclusionChanged() }
    }
    private func windowOcclusionChanged() {
        setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
    }
    /// Pauses (or resumes) every row's activity animation, down to a row badge's glyphs (cx-m8buz).
    func setWindowVisible(_ visible: Bool) {
        // Depth first in subview order; an indicator's own subviews are not entered. An explicit
        // stack, not a recursive local function (Swift 6.3.3's SendNonSendable pass crashed now and
        // then on capturing ones in Release).
        var pending: [NSView] = subviews.reversed()
        while let view = pending.popLast() {
            if let indicator = view as? StatusIndicatorView { indicator.isWindowVisible = visible } else { pending.append(contentsOf: view.subviews.reversed()) }
        }
    }
    nonisolated override var isFlipped: Bool { true }
    /// The list draws nothing itself (rows, group lines and decorations are subviews). A drawing
    /// layer-backed view this tall (1,000 rows) gets a visible-rect backing that AppKit marks for
    /// display on every scroll frame; with updateLayer it keeps no bitmap, so a scroll draws nothing here.
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var acceptsFirstResponder: Bool { true }
    var metrics: SidebarLayoutMetrics { .standard }
    var inset: CGFloat { SidebarStyle.horizontalInset }
    // MARK: - Hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
    override func mouseMoved(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        releaseHeldModelChange()
        setHovered(nil)
        hoverCards.pointerMoved(to: window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }
    /// Hover after a pointer event (`windowPoint`), or after rows moved or
    /// scrolled under a possibly still pointer (no point: the coordinator's
    /// pointer location, and the card re-hit-tests as a geometry change).
    func updateHover(_ windowPoint: NSPoint? = nil) {
        defer {
            if let windowPoint, let window {
                hoverCards.pointerMoved(to: window.convertPoint(toScreen: windowPoint))
            } else if !hoverFollowsScroll || hoverCards.machine.activeTarget != nil {
                hoverCards.geometryChanged(in: window)
            }
        }
        guard drag == nil, let window else { return setHovered(nil) }
        let point = convert(windowPoint ?? window.convertPoint(fromScreen: hoverCards.currentPointer()), from: nil)
        guard visibleRect.contains(point) else { return setHovered(nil) }
        setHovered(hoverHit(at: point)?.key)
    }
    /// The row the pointer at `point` hovers (`SidebarLayout.hoverRow`). The
    /// hover pill sits inside the drawn fill: `Metrics.space1` in from its top
    /// and bottom, corners rounded `Metrics.space1` more (Leo 2026-10-19).
    func hoverHit(at point: CGPoint) -> SidebarRow? {
        displayed.hoverRow(at: point, current: hoveredKey, frame: frame(for:),
                           cornerRadius: SidebarStyle.rowCornerRadius + Metrics.space1, inset: Metrics.space1)
    }
    /// The row a click at `point` acts on: the hovered row when the pointer
    /// hovers one, so a click never lands on a row other than the lit one;
    /// otherwise the row whose tile holds `point` (clicks split the gap).
    func clickHit(at point: CGPoint) -> SidebarRow? {
        hoverHit(at: point) ?? displayed.row(at: point.y)
    }
    func setHovered(_ key: SidebarRowKey?) {
        guard key != hoveredKey else { return }
        if let hoveredKey, let view = rowViews[hoveredKey] { setHover(false, on: view) }
        hoveredKey = key
        if let key, let view = rowViews[key] { setHover(true, on: view) }
    }
    private func setHover(_ hovered: Bool, on view: SidebarRowView) {
        view.isHovered = hovered
        guard hoverFollowsScroll else { return }
        view.fadesNextFill = false
        view.fadesNextHover = false
    }
}

/// A row still opening its slot (`SidebarListView.openingRows`): until when, and how. A row an insert opened outside
/// the realized rows opens the same way when a scroll brings it in before `until` (`RowMotion.place`).
struct SidebarRowOpening {
    /// The media time the open settles, on the spring it runs on.
    var until: CFTimeInterval
    /// The new row motion that opened it (`sidebar.insertMotion`); nil opens from zero height on `.move`.
    var motion: SidebarInsertMotion?
    /// How far its edges travel (`SidebarInsertMotion.travel`); nil is the whole distance.
    var travel: CGFloat?
}

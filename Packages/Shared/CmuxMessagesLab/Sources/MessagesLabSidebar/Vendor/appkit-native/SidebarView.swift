import AppKit

/// Messages' conversation list: a search field, the pinned grid and the rows, in one AppKit
/// scroll view. Rows are layers with bitmap contents, made only for the visible rows plus a
/// small margin (O(visible) per frame for any list length); bitmaps render on a background
/// queue ahead of the scroll and on the main thread only when a visible row has none.
///
/// Use: set `dataSource` and `delegate`, add `view` (or use it as an NSSplitViewItem's
/// sidebar), call `reloadData()` whenever the data changes. See appkit-native/SIDEBAR.md.
final class SidebarController: NSViewController, NSSearchFieldDelegate, NSMenuDelegate {
    weak var dataSource: SidebarDataSource?
    weak var delegate: SidebarDelegate?
    /// The selected conversation (nil: none, or a row of the host's extra search section).
    var selectedID: ConversationID? { highlightID.flatMap { SidebarController.isExtra($0) ? nil : $0 } }
    /// v1.1: extra search results from the host (a section under the matching conversations).
    weak var searchProvider: SidebarSearchProvider?
    /// v1.1: the unread dot's color, e.g. from the host's theme (nil: system blue). Dynamic
    /// colors follow the appearance.
    var unreadColor: NSColor? { didSet { colorsChanged() } }
    /// v1.1: the selection and menu-ring accent in a key window (nil: the system's selection
    /// color and accent). The selected row's text stays white on it.
    var selectionColor: NSColor? { didSet { colorsChanged() } }
    /// The resolved colors (tests).
    var currentPalette: SidebarPalette { palette }
    /// The highlighted row: a conversation id, or an extra result's internal id (`extraID`).
    private var highlightID: ConversationID?
    /// The highlighted row's id (tests): `selectedID`, or an extra result's internal id.
    var highlightedID: ConversationID? { highlightID }

    let searchField = NSSearchField()
    /// v1.2: the list's clock for the row times (default: the system clock; tests and still
    /// scenes give a fixed date). Changing it takes effect on the next reloadData().
    var now: () -> Date = { Date() }
    /// v1.2: the filter (default .all). Another filter hides the pinned grid and shows the matching
    /// conversations as rows, as a search does (to verify).
    var filter: SidebarFilter = .all { didSet { if filter != oldValue { filterChanged() } } }
    /// v1.2: the filters the menu offers (empty: no filter button). Default: all four.
    var availableFilters: [SidebarFilter] = SidebarFilter.allCases { didSet { filterButton.isHidden = availableFilters.count < 2; view.needsLayout = true } }
    /// The filter menu's button, right of the search field.
    let filterButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let scrollView = NSScrollView()
    let document = SidebarDocumentView()

    // Data.
    /// What the list shows: the data source's snapshot, plus the rows of the host's extra
    /// search section at the end while a search shows one.
    private(set) var snapshot = ConversationListSnapshot(items: [], pinned: [])
    private var baseSnapshot = ConversationListSnapshot(items: [], pinned: [])
    private var baseIndex: [ConversationID: Int] = [:]
    /// The first row of the extra section (nil: none) and its title.
    private(set) var extraStart: Int?
    private var extraTitle = ""
    private var extraSection: (query: String, section: SidebarSearchSection)?
    private var extraRequest: SidebarSearchRequest?
    private let sectionHeader = CALayer()
    private var sectionHeaderKey = ""
    /// Room for the extra section's title above its first row.
    static let sectionHeaderHeight: CGFloat = 28
    /// Extra results' ids inside the list (they never collide with conversation ids).
    static func extraID(_ id: String) -> ConversationID { "\u{1}sidebar.extra:" + id }
    static func isExtra(_ id: ConversationID) -> Bool { id.hasPrefix("\u{1}sidebar.extra:") }
    static func hostID(_ id: ConversationID) -> String { String(id.dropFirst("\u{1}sidebar.extra:".count)) }
    private var indexByID: [ConversationID: Int] = [:]
    /// Item indices of the pinned tiles (none while searching).
    private(set) var pinnedItems: [Int] = []
    /// Item indices of the list rows (the search results while searching).
    private(set) var rowItems: [Int] = []
    private var rowOfItem: [Int32] = []
    private var searchIndex: ConversationSearchIndex?
    private var searchGeneration = 0
    private(set) var query = ""
    private let searchQueue = DispatchQueue(label: "sidebar.search", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "sidebar.render", qos: .userInitiated)

    // Rendering.
    private(set) var metrics = SidebarMetrics(width: SidebarMetrics.preferredWidth)

    /// The host owns the width (its limits, storage and reset). The list works from
    /// `minimumWidth` (the compact, avatar-only list) to any width; `preferredWidth` is the
    /// width it is designed for (to verify against Messages' default).
    var minimumWidth: CGFloat { SidebarMetrics.minimumWidth }
    var preferredWidth: CGFloat? { SidebarMetrics.preferredWidth }
    private var palette = SidebarPalette.resolve(NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()) // no force unwrap
    private var generation = 0
    /// The palette, scale and color-space generation (tests).
    var renderGeneration: Int { generation }
    private var scale: CGFloat { document.window?.backingScaleFactor ?? 2 }
    private let cache = SidebarBitmapCache()
    let avatars = SidebarAvatarCache() // cmux: internal, the pin drag draws its tile
    private let textCache = SidebarTextCache()
    private let timeFormatter = ConversationTimeFormatter(yesterday: SidebarStrings.yesterday)
    private var bellSecondary: CGImage?, bellSelected: CGImage?, failedGlyph: CGImage?, failedSelected: CGImage?
    private var windowActive = true
    private var pending: Set<SidebarBitmapKey> = []
    private var rowLayers: [Int: SidebarRowLayer] = [:]
    private var pool: [SidebarRowLayer] = []
    // cmux: readable by the pin drag (Cmux/SidebarPinDragging.swift).
    private(set) var tileLayers: [SidebarRowLayer] = []
    // cmux: the pin drag in progress (Cmux/SidebarPinDrag.swift).
    let pinDragState = SidebarPinDragState()
    private let menuRing = CALayer()
    private var lastVisible: Range<Int> = 0..<0
    private var lastTop: CGFloat = 0
    let noResults = NSTextField(labelWithString: "")

    /// Counters for the bench and the self-test.
    struct Stats {
        /// The newest main-thread row renders (tests): "id v<version> w<width> e<emphasized> g<generation>".
        var syncLog: [String] = []
        mutating func logSync(_ k: SidebarBitmapKey) {
            syncRenders += 1
            syncLog.append("\(k.id) v\(k.version) w\(CrashGuard.int(k.width)) e\(k.emphasized ? 1 : 0) g\(k.generation)")
            if syncLog.count > 8 { syncLog.removeFirst() }
        }
        var syncRenders = 0; var asyncRenders = 0; var layersCreated = 0; var tiles = 0
        /// Visible rows of a width change whose text bitmap stayed (same line breaks and truncation).
        var keptTexts = 0
        /// Main-thread time in the list's own tiling, layout and selection (ms, cumulative).
        var workMs = 0.0
        /// Of a width change (ms, cumulative): the pinned tiles' redraw and the rows' relayout.
        var widthTilesMs = 0.0
        var widthRowsMs = 0.0 }
    private(set) var stats = Stats()
    var rowLayerCount: Int { rowLayers.count }
    var visibleRowRange: Range<Int> { lastVisible }

    /// Visible row layers whose text column overlaps their avatar (tests: none, after any
    /// reconfigure; cmux-next found the text at x 0 after a reselect).
    func rowsWithTextOverAvatar() -> [Int] {
        guard !metrics.compact else { return [] }
        return rowLayers.filter { !$0.value.isHidden && $0.value.content.frame.intersects($0.value.avatar.frame) }.map(\.key).sorted()
    }
    /// A pinned tile's laid-out parts in tile coordinates (tests): the unread dot (nil: hidden),
    /// the bubble without its tail (nil: none shown), the avatar and the tile's bounds.
    func tileGeometry(_ t: Int) -> (dot: CGRect?, bubble: CGRect?, avatar: CGRect, bounds: CGRect) {
        guard let l = tileLayers[checked: t] else { return (nil, nil, .zero, .zero) } // a stale tile index (no trap)
        let b = l.time.isHidden ? nil : CGRect(x: l.time.frame.minX + 1, y: l.time.frame.minY, width: l.time.frame.width - 1, height: l.time.frame.height - 5)
        return (l.dot.isHidden ? nil : l.dot.frame, b, l.avatar.frame, l.bounds)
    }

    /// A laid-out row's or tile's indicators (tests): the unread dot and the typing bubble shown,
    /// the bubble's dots pulsing (render-server animation); nil when the row has no layer.
    struct Indicators: Equatable { var dot: Bool; var typing: Bool; var pulsing: Bool }
    func indicators(_ h: Hit) -> Indicators? {
        let l: SidebarRowLayer?
        switch h {
        case let .tile(t): l = tileLayers[checked: t] // checked
        case let .row(r): l = rowLayers[r]
        }
        guard let l, !l.isHidden else { return nil }
        let t = l.typing.flatMap { $0.isHidden ? nil : $0 }
        return Indicators(dot: !l.dot.isHidden, typing: t != nil, pulsing: t?.isPulsing == true)
    }

    enum Hit: Equatable { case tile(Int), row(Int) }

    /// Visible rows that show no bitmap or one of another width (tests: 0 in every frame).
    func staleVisibleRows() -> Int {
        guard !metrics.compact else { return 0 }
        let clip = scrollView.contentView.bounds
        var n = 0
        for (r, l) in rowLayers where rowRect(r).intersects(clip) && (l.shownKey?.width != metrics.width) { n += 1 }
        for l in tileLayers where l.shownKey?.width != metrics.tileWidth { n += 1 }
        return n
    }

    override func loadView() {
        let root = SidebarRootView()
        root.controller = self
        view = root
        searchField.placeholderString = SidebarStrings.search
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .default
        root.addSubview(searchField)
        filterButton.isBordered = false
        filterButton.bezelStyle = .accessoryBarAction
        (filterButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        filterButton.setAccessibilityLabel(SidebarStrings.filter)
        filterButton.toolTip = SidebarStrings.filter
        updateFilterButton()
        root.addSubview(filterButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        document.controller = self
        root.addSubview(scrollView)
        // block observers on queue: .main (inline for a post on main), not selectors: a selector into
        // this main-actor controller trapped on a post off main.
        let nc = NotificationCenter.default
        clipObservers = [
            nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.clipMoved() },
            nc.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.colorsChanged() },
        ]

        menuRing.cornerRadius = SidebarMetrics.selectionRadius
        menuRing.borderWidth = 2
        menuRing.isHidden = true
        menuRing.zPosition = 5
        menuRing.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        document.layer?.addSublayer(menuRing)

        noResults.stringValue = SidebarStrings.noResults
        noResults.font = .systemFont(ofSize: 15, weight: .semibold)
        noResults.textColor = .secondaryLabelColor
        noResults.alignment = .center
        noResults.isHidden = true
        root.addSubview(noResults)
    }

    private var clipObservers: [NSObjectProtocol] = []
    deinit { clipObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Data

    /// Reads the data source again and redraws what changed (bitmaps are keyed by id and
    /// version, so unchanged rows keep theirs).
    func reloadData() {
        _ = view
        let fresh = dataSource?.sidebarSnapshot(self) ?? ConversationListSnapshot(items: [], pinned: [])
        reloadCount += 1
        if swipe != nil { closeSwipe(animated: false) }
        let motion = beginMotion(fresh)
        defer { endMotion(motion) }
        baseSnapshot = fresh
        var map: [ConversationID: Int] = [:]
        map.reserveCapacity(baseSnapshot.items.count)
        for (i, c) in baseSnapshot.items.enumerated() { map[c.id] = i }
        baseIndex = map
        snapshot = baseSnapshot
        indexByID = map
        searchIndex = nil
        if query.isEmpty {
            // A clear still on the search queue was built from the old snapshot: drop it.
            searchGeneration += 1
            stale.set(searchGeneration)
            applyRows(RowList.full(snapshot, indexByID, filter: filter))
        } else {
            runSearch(query)
        }
    }

    // MARK: Swipe actions (v1.2)

    /// A two-finger horizontal swipe on a row slides it and shows actions behind it: swipe right
    /// shows Mark as Read / Unread (blue), swipe left Hide / Show Alerts (indigo) and Delete (red).
    /// Past 60 % of the width the edge action runs on release; past half the buttons the row stays
    /// open; else it closes. A click on a button runs it; any other click or a scroll closes the row.
    /// Actions, colours, widths and thresholds UNVERIFIED (no reference of Messages' swipe).
    enum SwipeAction: Equatable { case read, mute, delete }
    enum SwipePhase { case began, changed, ended, cancelled }
    static let swipeButtonWidth: CGFloat = 74
    static let swipeFullFraction: CGFloat = 0.6
    private struct Swipe { var row: Int; var id: ConversationID; var offset: CGFloat; var open = false }
    private var swipe: Swipe?
    private let swipeStrip = CALayer()
    private let swipeMask = CALayer()
    /// Bumped by each swipe change: a close animation's end removes the buttons only if no newer swipe started.
    private var swipeToken = 0
    private var swipeButtons: [(action: SwipeAction, layer: CALayer)] = []
    /// Tests: the swiped row (`id`) and the strip's mask run the same move (duration and curve), so
    /// the strip's edge stays on the row's edge during a snap or a close.
    func swipeStripFollowsRow(_ id: ConversationID) -> Bool {
        guard let l = rowLayers.values.first(where: { $0.conversationID == id }),
              let a = l.animation(forKey: "move") as? CABasicAnimation,
              let m = swipeMask.animation(forKey: "move") as? CABasicAnimation,
              let b = swipeMask.animation(forKey: "reframe") as? CABasicAnimation else { return false }
        return a.duration == m.duration && m.duration == b.duration && a.timingFunction == m.timingFunction && m.timingFunction == b.timingFunction
    }
    /// The open or moving swipe (tests): the row's id and offset.
    var swipeState: (id: ConversationID, offset: CGFloat)? { swipe.map { ($0.id, $0.offset) } }

    private func swipeActions(_ c: ConversationSummary, leading: Bool) -> [SwipeAction] {
        let a = delegate?.sidebar(self, actionsFor: c.id) ?? []
        if leading { return a.contains(.markRead) ? [.read] : [] }
        return [a.contains(.mute) ? SwipeAction.mute : nil, a.contains(.delete) ? .delete : nil].compactMap { $0 }
    }
    /// One swipe event (the list view's scrollWheel, or a test). `dx`: the gesture's horizontal
    /// distance in this event (pt, right positive). Returns false when the event is not a swipe.
    @discardableResult
    func swipe(_ phase: SwipePhase, dx: CGFloat, at p: CGPoint) -> Bool {
        switch phase {
        case .began:
            guard query.isEmpty, case let .row(r)? = hit(p), !metrics.compact,
                  let c = rowItems[checked: r].flatMap({ snapshot.items[checked: $0] }) else { return false } // checked
            guard !Self.isExtra(c.id) else { return false }
            if let s = swipe, s.id != c.id { closeSwipe() }
            if swipe == nil { swipeToken += 1 }
            swipe = swipe ?? Swipe(row: r, id: c.id, offset: 0)
            return self.swipeBy(dx)
        case .changed:
            return swipe == nil ? false : swipeBy(dx)
        case .ended, .cancelled:
            guard let s = swipe, let c = rowItems[checked: s.row].flatMap({ snapshot.items[checked: $0] }) else { return false } // checked
            let n = CGFloat(swipeActions(c, leading: s.offset > 0).count)
            if phase == .ended, abs(s.offset) >= metrics.width * Self.swipeFullFraction, n > 0 {
                let act = s.offset > 0 ? swipeActions(c, leading: true).first : swipeActions(c, leading: false).last
                closeSwipe()
                if let act { runSwipe(act, c) }
            } else if phase == .ended, n > 0, abs(s.offset) >= n * Self.swipeButtonWidth / 2 {
                setSwipeOffset((s.offset > 0 ? 1 : -1) * n * Self.swipeButtonWidth, animated: true)
                swipe?.open = true
            } else {
                closeSwipe()
            }
            return true
        }
    }
    private func swipeBy(_ dx: CGFloat) -> Bool {
        guard let s = swipe, let c = rowItems[checked: s.row].flatMap({ snapshot.items[checked: $0] }) else { return false } // checked
        var o = s.offset + dx
        // No actions on a side: the row does not move that way.
        if o > 0, swipeActions(c, leading: true).isEmpty { o = 0 }
        if o < 0, swipeActions(c, leading: false).isEmpty { o = 0 }
        o = max(-metrics.width, min(metrics.width, o))
        setSwipeOffset(o, animated: false)
        return true
    }
    /// Slides the row and sizes the strip behind it (the revealed part only, so the glass shows elsewhere).
    private func setSwipeOffset(_ o: CGFloat, animated: Bool) {
        guard var s = swipe, let l = rowLayers[s.row], let c = rowItems[checked: s.row].flatMap({ snapshot.items[checked: $0] }) else { return } // checked
        let rect = rowRect(s.row)
        // Where the row shows now: its translation plus any running move (additive position).
        let old = l.affineTransform().tx + SidebarMotion.presented(l).position.x - l.position.x
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.setAffineTransform(CGAffineTransform(translationX: o, y: 0))
        if swipeStrip.superlayer == nil {
            swipeStrip.masksToBounds = true
            swipeStrip.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            document.layer?.insertSublayer(swipeStrip, at: 0)
        }
        let leading = o > 0
        let acts = o == 0 ? [] : swipeActions(c, leading: leading)
        if swipeButtons.map(\.action) != acts {
            // Also the buttons of a close still animating (its end does not remove them after a new swipe).
            swipeStrip.sublayers?.forEach { $0.removeFromSuperlayer() }
            swipeButtons = acts.map { a in
                let b = CALayer()
                b.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
                b.backgroundColor = swipeColor(a)
                let g = CALayer()
                g.contents = Self.symbol(swipeSymbol(a, c), size: 17, .white, view.effectiveAppearance, scale: renderContext.scale)
                g.contentsGravity = .center
                g.contentsScale = renderContext.scale
                g.actions = ["position": NSNull(), "bounds": NSNull()]
                g.name = "glyph"
                b.addSublayer(g)
                swipeStrip.addSublayer(b)
                return (a, b)
            }
        }
        // The strip covers the row; its mask is the revealed part (between the row's edge and the
        // list's edge), so the glass shows elsewhere. The mask and the buttons animate with the row's
        // own timing, so the strip's edge stays on the row's edge during a snap.
        let w = abs(o)
        swipeStrip.isHidden = w == 0 && !animated
        swipeStrip.frame = rect
        if swipeStrip.mask == nil {
            swipeMask.backgroundColor = CGColor(gray: 0, alpha: 1)
            swipeMask.actions = ["position": NSNull(), "bounds": NSNull()]
            swipeStrip.mask = swipeMask
        }
        let mask = swipeMask
        let oldMask = SidebarMotion.presented(mask).frame
        mask.frame = CGRect(x: leading ? 0 : rect.width - w, y: 0, width: w, height: rect.height)
        // Buttons share the revealed width while the finger moves; open, each is swipeButtonWidth.
        let n = CGFloat(max(1, swipeButtons.count))
        var oldButtons: [CGRect] = []
        for (k, b) in swipeButtons.enumerated() {
            oldButtons.append(SidebarMotion.presented(b.layer).frame)
            let bw = w / n
            b.layer.frame = CGRect(x: (leading ? 0 : rect.width - w) + CGFloat(k) * bw, y: 0, width: bw, height: rect.height)
            b.layer.sublayers?.first?.frame = b.layer.bounds
        }
        CATransaction.commit()
        if animated {
            SidebarMotion.move(l, by: CGPoint(x: old - o, y: 0))
            SidebarMotion.reframe(mask, from: oldMask)
            for (b, oldFrame) in zip(swipeButtons, oldButtons) { // no index math
                SidebarMotion.reframe(b.layer, from: oldFrame)
                if let g = b.layer.sublayers?.first { SidebarMotion.reframe(g, from: CGRect(origin: .zero, size: oldFrame.size)) }
            }
        }
        s.offset = o
        swipe = s
    }
    /// Closes the open row. Animated: the row slides back and the strip's mask shrinks with it,
    /// then the buttons go; not animated (a reload recycles the rows): at once.
    private func closeSwipe(animated: Bool = true) {
        guard let s = swipe else { return }
        swipe = nil
        swipeToken += 1
        let token = swipeToken
        let buttons = swipeButtons
        swipeButtons = []
        let finish = { [weak self] in
            guard let self, token == self.swipeToken else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.swipeStrip.isHidden = true
            buttons.forEach { $0.layer.removeFromSuperlayer() }
            CATransaction.commit()
        }
        guard animated, let l = rowLayers[s.row] else {
            rowLayers[s.row]?.setAffineTransform(.identity)
            buttons.forEach { $0.layer.removeFromSuperlayer() }
            swipeStrip.isHidden = true
            return
        }
        // Where the row shows now: its translation plus any running move (additive position).
        let old = l.affineTransform().tx + SidebarMotion.presented(l).position.x - l.position.x
        let oldMask = SidebarMotion.presented(swipeMask).frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(finish)
        l.setAffineTransform(.identity)
        swipeMask.frame = CGRect(x: old > 0 ? 0 : swipeStrip.bounds.width, y: 0, width: 0, height: swipeStrip.bounds.height)
        SidebarMotion.move(l, by: CGPoint(x: old, y: 0))
        SidebarMotion.reframe(swipeMask, from: oldMask)
        CATransaction.commit()
    }
    /// A click while a row is open: on one of its buttons runs it; anywhere closes the row. True: handled.
    func swipeClick(at p: CGPoint) -> Bool {
        guard let s = swipe else { return false }
        guard let c = rowItems[checked: s.row].flatMap({ snapshot.items[checked: $0] }) else { closeSwipe(); return true } // checked
        let hitButton = swipeButtons.first { swipeStrip.convert($0.layer.frame, to: document.layer).contains(p) }?.action
        closeSwipe()
        if let a = hitButton { runSwipe(a, c) }
        return true
    }
    private func runSwipe(_ a: SwipeAction, _ c: ConversationSummary) {
        switch a {
        case .read: delegate?.sidebar(self, setRead: c.unread, for: c.id)
        case .mute: delegate?.sidebar(self, setMuted: !c.muted, for: c.id)
        case .delete: delegate?.sidebar(self, delete: c.id)
        }
    }
    private func swipeColor(_ a: SwipeAction) -> CGColor {
        var out = NSColor.systemBlue.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            out = (a == .read ? NSColor.systemBlue : a == .mute ? NSColor.systemIndigo : NSColor.systemRed).cgColor
        }
        return out
    }
    private func swipeSymbol(_ a: SwipeAction, _ c: ConversationSummary) -> String {
        switch a {
        case .read: return c.unread ? "message" : "message.badge"
        case .mute: return c.muted ? "bell" : "bell.slash"
        case .delete: return "trash"
        }
    }

    // MARK: Pinned tile drag (v1.2)

    /// A drag of a pinned tile: the tile follows the pointer (lifted above the others), the other
    /// tiles make room at the slot under the pointer, and the drop asks the delegate to move the pin.
    /// Lift, room and drop use SidebarMotion.move (UNVERIFIED: no reference of Messages' drag).
    private struct TileDrag { var tile: Int; var start: CGPoint; var origin: CGPoint; var slot: Int; var active = false }
    private var tileDrag: TileDrag?
    /// Reloads so far (a drop that the host did not apply puts the tiles back).
    private var reloadCount = 0
    /// Starts moving after this distance (pt), as AppKit's drag threshold.
    static let dragThreshold: CGFloat = 4

    func tileDragBegan(_ t: Int, at p: CGPoint) {
        guard query.isEmpty, filter == .all, let tile = tileLayers[checked: t], pinnedItems.count > 1 else { return } // checked
        tileDrag = TileDrag(tile: t, start: p, origin: tile.position, slot: t)
    }
    func tileDragMoved(to p: CGPoint) {
        guard var d = tileDrag else { return }
        if !d.active {
            guard hypot(p.x - d.start.x, p.y - d.start.y) >= Self.dragThreshold else { return }
            d.active = true
        }
        guard let l = tileLayers[checked: d.tile] else { tileDrag = nil; return } // checked
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.zPosition = 10
        l.position = CGPoint(x: d.origin.x + p.x - d.start.x, y: d.origin.y + p.y - d.start.y)
        CATransaction.commit()
        let slot = slotAt(p)
        if slot != d.slot {
            d.slot = slot
            // The other tiles take their places in the order with the dragged tile at `slot`.
            var order = Array(pinnedItems.indices)
            order.remove(at: d.tile)
            order.insert(d.tile, at: slot)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (k, t) in order.enumerated() where t != d.tile {
                guard let m = tileLayers[checked: t] else { continue } // checked
                let old = SidebarMotion.presented(m).position
                let r = tileRect(k)
                m.position = CGPoint(x: r.midX, y: r.midY)
                m.removeAnimation(forKey: "move")
                SidebarMotion.move(m, by: CGPoint(x: old.x - m.position.x, y: old.y - m.position.y))
            }
            CATransaction.commit()
        }
        tileDrag = d
    }
    func tileDragEnded(at p: CGPoint) {
        guard let d = tileDrag else { return }
        tileDrag = nil
        guard d.active, let l = tileLayers[checked: d.tile],
              let id = pinnedItems[checked: d.tile].flatMap({ snapshot.items[checked: $0] })?.id else { return } // checked
        let before = reloadCount
        l.zPosition = 0
        if d.slot != d.tile { delegate?.sidebar(self, movePinned: id, to: d.slot) }
        if reloadCount == before {
            // Not moved (same slot, or the host kept the order): every tile goes back to its place.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for t in pinnedItems.indices {
                guard let m = tileLayers[checked: t] else { continue } // checked
                let old = SidebarMotion.presented(m).position
                let r = tileRect(t)
                m.position = CGPoint(x: r.midX, y: r.midY)
                m.removeAnimation(forKey: "move")
                SidebarMotion.move(m, by: CGPoint(x: old.x - m.position.x, y: old.y - m.position.y))
            }
            CATransaction.commit()
        }
    }
    /// The pinned slot under a document point (clamped to the grid).
    private func slotAt(_ p: CGPoint) -> Int {
        let cols = metrics.columns, tw = metrics.tileWidth, th = metrics.tileHeight
        let x0 = tileRect(0).minX
        // no trap on NaN (a zero tile size) or a huge position
        let c = min(cols - 1, max(0, CrashGuard.int((p.x - x0) / tw, in: CrashGuard.rowRange)))
        let r = max(0, CrashGuard.int(p.y / th, in: CrashGuard.rowRange))
        return min(pinnedItems.count - 1, r * cols + c)
    }

    // MARK: Filter (v1.2)

    private func filterChanged() {
        updateFilterButton()
        if query.isEmpty { reloadData() } else { runSearch(query) }
    }
    /// The button's menu: one item per available filter, a check on the current one; the symbol
    /// is filled while a filter other than All is on (to verify).
    private func updateFilterButton() {
        let m = NSMenu()
        let on = filter != .all
        let symbol = NSImage(systemSymbolName: on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                             accessibilityDescription: SidebarStrings.filter)
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = symbol
        m.addItem(head)   // a pull-down's first item is its title
        for f in availableFilters {
            let it = NSMenuItem(title: SidebarStrings.filterName(f), action: #selector(pickFilter(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = f.rawValue
            it.state = f == filter ? .on : .off
            m.addItem(it)
        }
        filterButton.menu = m
        filterButton.contentTintColor = on ? (selectionColor ?? .controlAccentColor) : .secondaryLabelColor
        filterButton.isHidden = availableFilters.count < 2
    }
    @objc private func pickFilter(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let f = SidebarFilter(rawValue: raw) { filter = f }
    }

    // MARK: Motion (SidebarMotion: render-server animations of a data change)

    /// Typing bubbles that start in this reload (configure pops them in once).
    private var typingAppeared: Set<ConversationID> = []
    private var typingIDs: Set<ConversationID>?
    /// Motions started by the last reload (tests): ids that moved, appeared, typing in and out.
    struct MotionLog: Equatable { var moved: Set<ConversationID> = []; var appeared: Set<ConversationID> = []
        var typingIn: Set<ConversationID> = []; var typingOut: Set<ConversationID> = [] }
    private(set) var lastMotion = MotionLog()
    private struct MotionStart { var frames: [ConversationID: CGRect]; var typingOut: Set<ConversationID>; var typingStarted: Set<ConversationID>; var width: CGFloat }

    /// Before a reload: where each laid-out row and tile is, and the typing bubbles that end
    /// (they leave their rows now and fade out in the document).
    private func beginMotion(_ fresh: ConversationListSnapshot) -> MotionStart? {
        let typingNow = Set(fresh.items.lazy.filter(\.typing).map(\.id))
        defer { typingIDs = typingNow }
        lastMotion = MotionLog()
        guard SidebarMotion.enabled, query.isEmpty, view.window != nil, let old = typingIDs else { typingAppeared = []; return nil }
        typingAppeared = typingNow.subtracting(old)
        var frames: [ConversationID: CGRect] = [:]
        let clip = scrollView.contentView.bounds
        for l in Array(rowLayers.values) + tileLayers where !l.isHidden {
            guard let id = l.conversationID, l.frame.intersects(clip) else { continue }
            frames[id] = l.frame
        }
        var out = Set<ConversationID>()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in Array(rowLayers.values) + tileLayers where !l.isHidden {
            guard let id = l.conversationID, old.contains(id), !typingNow.contains(id), let t = l.detachTyping() else { continue }
            let p = l.convert(t.position, to: document.layer)
            document.layer?.addSublayer(t)
            t.position = p
            SidebarMotion.typingOutAndRemove(t)
            out.insert(id)
        }
        CATransaction.commit()
        return MotionStart(frames: frames, typingOut: out, typingStarted: typingAppeared, width: metrics.width)
    }
    /// After a reload: every laid-out row and tile that was on screen moves from its old place;
    /// one that was not fades in. Pinning and unpinning move the conversation between a row and a tile.
    private func endMotion(_ m: MotionStart?) {
        defer { typingAppeared = [] }
        guard let m, m.width == metrics.width, query.isEmpty else { return }
        var log = MotionLog(typingOut: m.typingOut)
        log.typingIn = m.typingStarted.subtracting(typingAppeared)
        let clip = scrollView.contentView.bounds
        for l in Array(rowLayers.values) + tileLayers where !l.isHidden {
            guard let id = l.conversationID, l.frame.intersects(clip) else { continue }
            if let f = m.frames[id] {
                let delta = CGPoint(x: f.midX - l.frame.midX, y: f.midY - l.frame.midY)
                if abs(delta.x) > 0.25 || abs(delta.y) > 0.25 {
                    SidebarMotion.move(l, by: delta)
                    if f.size != l.frame.size { SidebarMotion.appear(l) }   // a row became a tile or back
                    log.moved.insert(id)
                }
            } else if !m.frames.isEmpty {
                SidebarMotion.appear(l)
                log.appeared.insert(id)
            }
        }
        lastMotion = log
    }

    /// What the list shows: the pinned tiles and the rows (item indices), and each item's row.
    /// Built off the main thread for a search and for the list after a search is cleared.
    private struct RowList {
        var pinned: [Int]
        var rows: [Int]
        var rowOf: [Int32]
        var searching: Bool
        var extraStart: Int? = nil
        var extraTitle = ""
        init(pinned: [Int], rows: [Int], count: Int, searching: Bool) {
            self.pinned = pinned; self.rows = rows; self.searching = searching
            rowOf = [Int32](repeating: -1, count: count)
            for (r, i) in rows.enumerated() { if let slot = rowOf.checkedIndex(i) { rowOf[slot] = Int32(clamping: r) } } // checked
        }
        /// The pinned grid and every other conversation in the snapshot's order.
        static func full(_ s: ConversationListSnapshot, _ index: [ConversationID: Int], filter: SidebarFilter = .all) -> RowList {
            if filter != .all {
                // no index math
                return RowList(pinned: [], rows: zip(s.items.indices, s.items).filter { filter.includes($0.1) }.map(\.0), count: s.items.count, searching: true)
            }
            // All: spam and deleted conversations stay out (also out of the pinned grid).
            let pinned = s.pinned.compactMap { index[$0] }.filter { s.items[checked: $0].map(filter.includes) ?? false } // checked
            var isPinned = [Bool](repeating: false, count: s.items.count)
            for i in pinned { if let slot = isPinned.checkedIndex(i) { isPinned[slot] = true } } // checked
            // no index math
            return RowList(pinned: pinned, rows: zip(s.items.indices, zip(isPinned, s.items)).filter { !$0.1.0 && filter.includes($0.1.1) }.map(\.0), count: s.items.count, searching: false)
        }
    }

    func summary(_ id: ConversationID) -> ConversationSummary? { indexByID[id].flatMap { snapshot.items[checked: $0] } } // checked
    /// the conversation under a hit, nil when the hit is stale (no trap).
    func summary(_ h: Hit) -> ConversationSummary? { item(h).flatMap { snapshot.items[checked: $0] } }

    private func applyRows(_ list: RowList) {
        let t0 = beginWork()
        defer { endWork(t0) }
        pinnedItems = list.pinned
        rowItems = list.rows
        rowOfItem = list.rowOf
        extraStart = list.extraStart
        extraTitle = list.extraTitle
        noResults.isHidden = !(list.searching && list.rows.isEmpty)
        layoutSectionHeader()
        for (_, l) in rowLayers { recycle(l) }
        rowLayers.removeAll()
        lastVisible = 0..<0
        rebuildTiles()
        layoutDocument()
        tile(force: true)
        updateAccessibility()
        pinDragDidReload() // cmux: a drag follows the new data; a drop lands
    }

    // MARK: Geometry

    var pinnedHeight: CGFloat { metrics.pinnedHeight(count: pinnedItems.count) }
    func rowRect(_ r: Int) -> CGRect {
        CGRect(x: 0, y: rowTop(r), width: metrics.width, height: SidebarMetrics.rowHeight)
    }
    /// A row's top: rows of the extra section sit below its title.
    private func rowTop(_ r: Int) -> CGFloat {
        pinnedHeight + CGFloat(r) * SidebarMetrics.rowHeight + (extraStart.map { r >= $0 ? Self.sectionHeaderHeight : 0 } ?? 0)
    }
    /// The row at a document y (fractional: the part below the row's top), the inverse of rowTop.
    private func rowPosition(_ y: CGFloat) -> CGFloat {
        let rh = SidebarMetrics.rowHeight
        var d = y - pinnedHeight
        if let e = extraStart, d > CGFloat(e) * rh {
            d = max(CGFloat(e) * rh, d - Self.sectionHeaderHeight)
        }
        return d / rh
    }
    /// The extra section's title rect (nil: no section).
    var sectionHeaderRect: CGRect? {
        extraStart.map { CGRect(x: 0, y: pinnedHeight + CGFloat($0) * SidebarMetrics.rowHeight, width: metrics.width, height: Self.sectionHeaderHeight) }
    }
    /// The section title: one small bitmap, drawn when the title, width or palette changes.
    private func layoutSectionHeader() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if sectionHeader.superlayer == nil {
            sectionHeader.contentsGravity = .topLeft
            sectionHeader.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
            document.layer?.addSublayer(sectionHeader)
        }
        guard let r = sectionHeaderRect, !metrics.compact else { sectionHeader.isHidden = true; return }
        sectionHeader.isHidden = false
        sectionHeader.frame = r
        let ctx = renderContext
        let key = "\(extraTitle)|\(r.width)|\(ctx.generation)|\(ctx.scale)"
        guard key != sectionHeaderKey else { return }
        sectionHeaderKey = key
        sectionHeader.contentsScale = ctx.scale
        sectionHeader.contents = SidebarDraw.sectionHeader(extraTitle, width: r.width, ctx: ctx)
    }
    func selectionRect(_ r: Int) -> CGRect { rowRect(r).insetBy(dx: SidebarMetrics.selectionInsetX, dy: 0) }
    func tileRect(_ t: Int) -> CGRect { metrics.tileRect(t) }

    func hit(_ p: CGPoint) -> Hit? {
        if p.y < pinnedHeight {
            for t in pinnedItems.indices where tileRect(t).contains(p) { return .tile(t) }
            return nil
        }
        if let h = sectionHeaderRect, h.contains(p) { return nil }
        let r = CrashGuard.int(rowPosition(p.y).rounded(.down), in: CrashGuard.rowRange) // no trap on NaN
        return r >= 0 && r < rowItems.count ? .row(r) : nil
    }
    func item(_ h: Hit) -> Int? { switch h { case let .tile(t): return pinnedItems[checked: t]; case let .row(r): return rowItems[checked: r] } } // nil when stale
    func rect(_ h: Hit) -> CGRect {
        switch h { case let .tile(t): return tileRect(t).insetBy(dx: 2, dy: 2); case let .row(r): return selectionRect(r) }
    }
    /// A conversation's tile or row in screen coordinates (accessibility; .zero when not shown).
    func screenRect(of id: ConversationID) -> NSRect {
        guard let h = position(of: id), let w = document.window else { return .zero }
        return w.convertToScreen(document.convert(rect(h), to: nil))
    }
    /// Where a conversation is shown now (nil: filtered out).
    func position(of id: ConversationID) -> Hit? {
        guard let i = indexByID[id] else { return nil }
        if let t = pinnedItems.firstIndex(of: i) { return .tile(t) }
        guard let row = rowOfItem[checked: i] else { return nil } // checked
        let r = Int(truncatingIfNeeded: row) // Int32 widens exactly
        return r >= 0 ? .row(r) : nil
    }

    /// A width change keeps a visible row's text bitmap when its lines break and truncate the same
    /// way (configure, flushBatch). `--sidebar-width-redraw` or MLAB_EXP=sbredraw: every visible
    /// row's text is drawn again at each width (the rule before; the A/B control).
    static let keepSameText: Bool = {
        let exp = (ProcessInfo.processInfo.environment["MLAB_EXP"] ?? "").split(separator: ",")
        return !(CommandLine.arguments.contains("--sidebar-width-redraw") || exp.contains("sbredraw"))
    }()

    func layout(in bounds: CGRect) {
        let M = SidebarMetrics.self
        let top = M.titlebar
        let fb: CGFloat = filterButton.isHidden || bounds.width < SidebarMetrics.compactBelow ? 0 : 28
        searchField.frame = CGRect(x: M.searchInsetX, y: top, width: max(0, bounds.width - 2 * M.searchInsetX - fb), height: M.searchHeight)
        filterButton.frame = CGRect(x: bounds.width - M.searchInsetX - fb + 2, y: top + (M.searchHeight - 26) / 2, width: max(0, fb - 2), height: 26)
        let listTop = top + M.searchHeight + M.searchBottomGap
        let sf = CGRect(x: 0, y: listTop, width: bounds.width, height: max(0, bounds.height - listTop))
        if scrollView.frame != sf { scrollView.frame = sf }
        noResults.frame = CGRect(x: 0, y: listTop + 40, width: bounds.width, height: 24)
        let w = scrollView.contentSize.width
        if w > 0, w != metrics.width {
            let t0 = beginWork()
            defer { endWork(t0) }
            metrics = SidebarMetrics(width: w)
            // Every frame of a live resize: the visible rows' text is redrawn at this exact
            // width (in parallel, from cached measurement); avatars, dots and times only move.
            let a = CACurrentMediaTime()
            rebuildTiles()
            let b = CACurrentMediaTime()
            layoutDocument()
            layoutSectionHeader()
            tile(force: true)
            stats.widthTilesMs += (b - a) * 1000
            stats.widthRowsMs += (CACurrentMediaTime() - b) * 1000
        }
    }

    private func layoutDocument() {
        let h = rowTop(rowItems.count) + 8
        let f = CGRect(x: 0, y: 0, width: metrics.width, height: max(h, scrollView.contentSize.height))
        if document.frame != f { document.frame = f }
    }

    // MARK: Tiling (O(visible))

    private func clipMoved() { tile(force: false) }  // no selector

    var renderContext: SidebarRenderContext { // cmux: internal, the pin drag draws its tile
        SidebarRenderContext(metrics: metrics, palette: palette, scale: scale,
                             space: document.window?.screen?.colorSpace?.cgColorSpace ?? SidebarDraw.p3, generation: generation,
                             bellSecondary: bellSecondary, bellSelected: bellSelected,
                             failed: failedGlyph, failedSelected: failedSelected, now: now())
    }

    func key(_ kind: SidebarBitmapKey.Kind, item i: Int, emphasized: Bool) -> SidebarBitmapKey? { // nil for a stale item
        guard let c = snapshot.items[checked: i] else { return nil }
        return key(kind, summary: c, emphasized: emphasized)
    }
    private func key(_ kind: SidebarBitmapKey.Kind, summary c: ConversationSummary, emphasized: Bool) -> SidebarBitmapKey {
        SidebarBitmapKey(kind: kind, id: c.id, version: c.version, width: kind == .row ? metrics.width : kind == .tile ? metrics.tileWidth : 0,
                                emphasized: emphasized, generation: generation)
    }
    private func emphasized(_ i: Int) -> Bool { windowActive && (snapshot.items[checked: i].map { $0.id == highlightID } ?? false) } // checked

    /// Lays out the rows the clip view shows, with a margin of a few rows; renders missing
    /// visible bitmaps now and the next screen's in the background.
    func tile(force: Bool) {
        guard !rowItems.isEmpty || !rowLayers.isEmpty else { return }
        let clip = scrollView.contentView.bounds
        let margin = 3
        let top = CrashGuard.int(rowPosition(clip.minY).rounded(.down), in: CrashGuard.rowRange) // no trap on NaN
        let bottom = CrashGuard.int(rowPosition(clip.maxY).rounded(.up), in: CrashGuard.rowRange)
        let first = max(0, top - margin)
        let last = min(rowItems.count, bottom + margin)
        let range = first < last ? first..<last : 0..<0
        let direction: CGFloat = clip.minY >= lastTop ? 1 : -1
        lastTop = clip.minY
        if !force, range == lastVisible { return }
        let t0 = beginWork()
        defer { endWork(t0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        batching = true
        for (r, l) in rowLayers where !range.contains(r) { recycle(l); rowLayers[r] = nil }
        let visible = top..<max(top, bottom) // the clamped positions above
        for r in range {
            // A row already laid out keeps its layer as is (selection and data changes
            // reconfigure it through refresh); only new rows cost work.
            if !force, let l = rowLayers[r] {
                // A margin row whose background bitmap has not arrived yet: draw it now.
                if l.shownKey == nil, visible.contains(r) { configure(l, row: r, sync: true) }
                continue
            }
            let l = rowLayers[r] ?? dequeue()
            rowLayers[r] = l
            configure(l, row: r, sync: visible.contains(r))
        }
        flushBatch()
        CATransaction.commit()
        lastVisible = range
        prefetch(from: direction > 0 ? range.upperBound : range.lowerBound - 1, direction: direction > 0 ? 1 : -1, count: 14)
        if !force { updateAccessibility() }
    }

    /// Outermost list work only (tiling inside a reload is not counted twice).
    private var workDepth = 0
    private func beginWork() -> CFTimeInterval { workDepth += 1; return CACurrentMediaTime() }
    private func endWork(_ t0: CFTimeInterval) {
        workDepth -= 1
        if workDepth == 0 { stats.workMs += (CACurrentMediaTime() - t0) * 1000 }
    }

    /// Visible rows with no bitmap in one tiling pass: drawn on all cores at once (the main
    /// thread takes a share), so a jump or a width change costs about one row's time per core.
    private var batching = false
    /// A batch row: its layer, key and summary, and the text bitmap the layer shows now when it is
    /// this row's at another width (with that bitmap's layout): kept if the new width breaks and
    /// truncates the text the same way.
    private var batch: [(SidebarRowLayer, SidebarBitmapKey, ConversationSummary, (CGImage, SidebarDraw.RowTextLayout)?)] = []
    private func flushBatch() {
        batching = false
        guard !batch.isEmpty else { return }
        let work = batch
        batch.removeAll(keepingCapacity: true)
        let job = rowJob()
        var out = [(time: CGImage, text: CGImage?, layout: SidebarDraw.RowTextLayout)?](repeating: nil, count: work.count)
        let cachedTimes = work.map { cache.image(timeKey($0.1)) }
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: work.count) { j in
                guard let w = work[checked: j] else { return } // checked (an unsafe buffer does not check)
                if let slot = o.checkedIndex(j) { o[slot] = job(w.2, w.1, cachedTimes[checked: j] ?? nil, w.3?.1) }
            }
        }
        for ((l, k, _, shown), result) in zip(work, out) { // no index math
            guard let r = result else { continue }
            cache.insert(timeKey(k), r.time)
            if let text = r.text {
                stats.logSync(k)
                cache.insert(k, text)
                show(l, k, time: r.time, text: text, layout: r.layout)
            } else if let shown {
                stats.keptTexts += 1
                show(l, k, time: r.time, text: shown.0, layout: r.layout)
            }
        }
    }

    /// Renders a row's time and text from values only (any thread). With the layout of the text
    /// bitmap on screen: no text bitmap (nil) when the layout is the same.
    /// nil when a bitmap cannot be allocated; the row then waits undrawn (no trap).
    private func rowJob() -> (ConversationSummary, SidebarBitmapKey, CGImage?, SidebarDraw.RowTextLayout?)
        -> (time: CGImage, text: CGImage?, layout: SidebarDraw.RowTextLayout)? {
        let ctx = renderContext, time = timeFormatter, text = textCache
        return { c, k, cachedTime, shown in
            guard let t = cachedTime ?? SidebarDraw.rowTime(c, emphasized: k.emphasized, ctx: ctx, time: time),
                  let x = SidebarDraw.rowText(c, emphasized: k.emphasized, ctx: ctx, timeWidth: SidebarDraw.rowTimeWidth(t, scale: ctx.scale),
                                              text: text, unless: shown)
            else { return nil }
            return (t, x.image, x.layout)
        }
    }
    private func timeKey(_ k: SidebarBitmapKey) -> SidebarBitmapKey {
        var t = k; t.kind = .time; t.width = 0; return t
    }
    private func show(_ l: SidebarRowLayer, _ k: SidebarBitmapKey, time: CGImage, text: CGImage, layout: SidebarDraw.RowTextLayout? = nil) {
        l.shownLayout = layout
        l.shownText = text
        let s = renderContext.scale
        let tw = CGFloat(time.width) / s
        l.time.contents = time
        l.time.frame = CGRect(x: metrics.width - SidebarMetrics.textRightInset - tw, y: 0, width: tw, height: SidebarMetrics.rowHeight)
        l.content.contents = text
        l.content.frame = CGRect(x: SidebarMetrics.textX, y: 0, width: metrics.textWidth, height: SidebarMetrics.rowHeight)
        l.shownKey = k
    }

    private func dequeue() -> SidebarRowLayer {
        if let l = pool.popLast() { l.isHidden = false; return l }
        let l = SidebarRowLayer()
        stats.layersCreated += 1
        document.layer?.addSublayer(l)
        return l
    }
    private func recycle(_ l: SidebarRowLayer) {
        l.isHidden = true
        l.conversationID = nil
        l.setAffineTransform(.identity)
        l.removeAnimation(forKey: "move"); l.removeAnimation(forKey: "appear")
        l.shownKey = nil
        l.shownLayout = nil
        l.shownText = nil
        l.content.contents = nil
        l.time.contents = nil
        l.setTyping(nil)
        pool.append(l)
    }

    private func configure(_ l: SidebarRowLayer, row r: Int, sync: Bool) {
        guard let i = rowItems[checked: r], let c = snapshot.items[checked: i] else { return } // a stale row draws nothing
        let frame = rowRect(r)
        let selected = c.id == highlightID
        let k = key(.row, summary: c, emphasized: emphasized(i))
        l.frame = frame
        l.conversationID = c.id
        // The text column (show() sets the same frame; it is skipped when the bitmap is unchanged).
        l.content.frame = CGRect(x: SidebarMetrics.textX, y: 0, width: metrics.textWidth, height: SidebarMetrics.rowHeight)
        l.selection.frame = CGRect(x: SidebarMetrics.selectionInsetX, y: 0, width: frame.width - 2 * SidebarMetrics.selectionInsetX, height: frame.height)
        l.selection.cornerRadius = SidebarMetrics.selectionRadius
        l.selection.isHidden = !selected
        l.selection.backgroundColor = windowActive ? palette.selectionActive : palette.selectionInactive
        // The separator under the text, hidden next to the selection (as NSTableView does).
        let nextSelected = rowItems.dropFirst(r + 1).first.flatMap { snapshot.items[checked: $0] }.map { $0.id == highlightID } ?? false
        l.separator.isHidden = selected || nextSelected || r == rowItems.count - 1 || r + 1 == extraStart
        let s = 1 / max(1, document.window?.backingScaleFactor ?? 2)
        l.separator.frame = CGRect(x: SidebarMetrics.textX, y: frame.height - s, width: frame.width - SidebarMetrics.textX - SidebarMetrics.separatorInsetRight, height: s)
        l.separator.backgroundColor = palette.separator
        // Avatar and unread dot: no dependence on the width (only their x in the compact list).
        let compact = metrics.compact
        let ah = SidebarMetrics.avatar
        l.avatar.frame = CGRect(x: metrics.rowAvatarX, y: ((frame.height - ah) / 2).rounded(), width: ah, height: ah)
        if l.avatarSpec != c.avatar || l.avatarGeneration != generation {
            l.avatar.contents = avatars.image(c.avatar, diameter: ah, ctx: renderContext)
            l.avatarSpec = c.avatar; l.avatarGeneration = generation
        }
        let d = SidebarMetrics.dotDiameter
        l.dot.isHidden = !c.unread
        l.dot.frame = CGRect(x: metrics.dotCenterX - d / 2, y: frame.height / 2 - d / 2, width: d, height: d)
        l.dot.cornerRadius = d / 2
        l.dot.backgroundColor = k.emphasized ? palette.selectedText : palette.unread
        l.separator.isHidden = l.separator.isHidden || compact
        l.time.isHidden = compact
        l.content.isHidden = compact
        if c.typing, !compact {
            l.setTyping(palette, scale: renderContext.scale)
            l.typing?.position = CGPoint(x: SidebarMetrics.textX + SidebarTypingLayer.size.width / 2, y: SidebarMetrics.previewBaseline - 4)
            if let t = l.typing, typingAppeared.remove(c.id) != nil { SidebarMotion.typingIn(t) }
        } else {
            l.setTyping(nil)
        }
        l.contentsScaleAll(renderContext.scale)
        if compact { l.shownKey = k; return }
        if l.shownKey == k { return }
        if let text = cache.image(k), let time = cache.image(timeKey(k)) {
            show(l, k, time: time, text: text)
        } else if sync, batching {
            // Drawn with the other visible rows of this pass, in parallel (flushBatch). A width
            // change keeps the text bitmap on screen when it is this row's, drawn at another width,
            // and the new width breaks and truncates its lines the same way (the same pixels: in a
            // divider drag most rows' text does not change; the redraw of every visible row was
            // up to 40 % of the missed frames on the idle mini, macOS 26).
            var shown: (CGImage, SidebarDraw.RowTextLayout)?
            if Self.keepSameText, let old = l.shownKey, old.kind == .row, old.id == k.id, old.version == k.version,
               old.emphasized == k.emphasized, old.generation == k.generation, let layout = l.shownLayout,
               let image = l.shownText {
                shown = (image, layout)
            }
            l.shownKey = nil
            batch.append((l, k, c, shown))
        } else if sync, let r = rowJob()(c, k, cache.image(timeKey(k)), nil) { // an unallocated row stays undrawn
            stats.logSync(k)
            cache.insert(timeKey(k), r.time)
            if let text = r.text { cache.insert(k, text); show(l, k, time: r.time, text: text, layout: r.layout) }
        } else {
            l.shownKey = nil
            request(k, item: i)
        }
    }

    /// Background render of a row's time and text; the result goes to whichever layer shows that key.
    private func request(_ k: SidebarBitmapKey, item i: Int) {
        guard !pending.contains(k), !cache.contains(k), let c = snapshot.items[checked: i] else { return } // checked
        pending.insert(k)
        let job = rowJob(), cachedTime = cache.image(timeKey(k))
        renderQueue.async { [weak self] in
            let r = job(c, k, cachedTime, nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(k)
                guard let r else { return } // an unallocated row stays undrawn
                guard k.generation == self.generation, k.width == self.metrics.width else { return }
                self.stats.asyncRenders += 1
                self.cache.insert(self.timeKey(k), r.time)
                guard let text = r.text else { return }
                self.cache.insert(k, text)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                for (row, l) in self.rowLayers where l.shownKey == nil && row < self.rowItems.count
                    && self.rowItems[checked: row].flatMap({ self.key(.row, item: $0, emphasized: self.emphasized($0)) }) == k {
                    self.show(l, k, time: r.time, text: text, layout: r.layout)
                }
                CATransaction.commit()
            }
        }
    }

    private func prefetch(from start: Int, direction: Int, count: Int) {
        var r = start
        for _ in 0..<count {
            guard r >= 0, r < rowItems.count else { return }
            guard let i = rowItems[checked: r], let k = key(.row, item: i, emphasized: emphasized(i)) else { return }
            if !cache.contains(k) { request(k, item: i) }
            r += direction
        }
    }

    // MARK: Pinned tiles

    private func rebuildTiles() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while tileLayers.count > pinnedItems.count { tileLayers.removeLast().removeFromSuperlayer() }
        while tileLayers.count < pinnedItems.count {
            let l = SidebarRowLayer()
            l.separator.isHidden = true
            document.layer?.addSublayer(l)
            tileLayers.append(l)
        }
        // Tile name and bubble bitmaps not in the cache: drawn in parallel first. A width
        // change redraws only the parts that it truncates or wraps.
        let ctx = renderContext
        var work: [(SidebarBitmapKey, ConversationSummary)] = []
        if !metrics.compact {
            for i in pinnedItems { // no index math; a stale item is skipped
                guard let c = snapshot.items[checked: i], let keys = tileKeys(i) else { continue }
                for k in [keys.name, keys.bubble].compactMap({ $0 }) where !cache.contains(k) { work.append((k, c)) }
            }
        }
        if work.count > 1 {
            var images = [CGImage?](repeating: nil, count: work.count)
            images.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: work.count) { j in
                    if let w = work[checked: j], let slot = out.checkedIndex(j) { out[slot] = SidebarController.tilePart(w.0, w.1, ctx) }
                }
            }
            for (w, image) in zip(work, images) { if let img = image { cache.insert(w.0, img); stats.tiles += 1 } } // no index math
        }
        for t in pinnedItems.indices { configureTile(t) }
        CATransaction.commit()
    }

    /// Natural name and one-line preview widths per conversation version (main thread).
    private var tileNatural: [ConversationID: (version: Int, name: CGFloat, bubble: CGFloat)] = [:]
    private func natural(_ c: ConversationSummary) -> (name: CGFloat, bubble: CGFloat) {
        if let n = tileNatural[c.id], n.version == c.version { return (n.name, n.bubble) }
        let n = SidebarDraw.tileNatural(c)
        tileNatural[c.id] = (c.version, n.name, n.bubble)
        return n
    }
    /// The keys of a tile's name and bubble (nil: no bubble) at the current width.
    private func tileKeys(_ i: Int) -> (name: SidebarBitmapKey, bubble: SidebarBitmapKey?)? { // nil for a stale item
        guard let c = snapshot.items[checked: i] else { return nil }
        let n = natural(c), tw = metrics.tileWidth
        return SidebarController.tileKeys(c, natural: n, tileWidth: tw, emphasized: emphasized(i), generation: generation)
    }
    static func tileKeys(_ c: ConversationSummary, natural n: (name: CGFloat, bubble: CGFloat), tileWidth tw: CGFloat,
                         emphasized: Bool, generation: Int) -> (name: SidebarBitmapKey, bubble: SidebarBitmapKey?) {
        let name = SidebarBitmapKey(kind: .tile, id: c.id, version: c.version, width: SidebarDraw.tileNameKeyWidth(natural: n.name, tileWidth: tw),
                                    emphasized: emphasized, generation: generation)
        let bubble = c.unread && !c.typing
            ? SidebarBitmapKey(kind: .tileBubble, id: c.id, version: c.version, width: SidebarDraw.tileBubbleKeyWidth(natural: n.bubble, tileWidth: tw),
                               emphasized: false, generation: generation) : nil
        return (name, bubble)
    }
    /// Renders one tile part for its key (any thread).
    static func tilePart(_ k: SidebarBitmapKey, _ c: ConversationSummary, _ ctx: SidebarRenderContext) -> CGImage? { // nil when unallocated
        k.kind == .tileBubble ? SidebarDraw.tileBubbleImage(c, keyWidth: k.width, ctx: ctx)
            : SidebarDraw.tileNameImage(c, emphasized: k.emphasized, keyWidth: k.width, ctx: ctx)
    }
    private func tileImage(_ k: SidebarBitmapKey, _ c: ConversationSummary) -> CGImage? {
        if let img = cache.image(k) { return img }
        guard let img = SidebarController.tilePart(k, c, renderContext) else { return nil }
        stats.tiles += 1
        cache.insert(k, img)
        return img
    }

    private func configureTile(_ t: Int) {
        guard let l = tileLayers[checked: t], let i = pinnedItems[checked: t], let c = snapshot.items[checked: i] else { return }
        let f = tileRect(t)
        let s = renderContext.scale
        l.frame = f
        l.conversationID = c.id
        l.selection.frame = l.bounds.insetBy(dx: 2, dy: 2)
        l.selection.cornerRadius = SidebarMetrics.pinSelectionRadius
        l.selection.isHidden = c.id != highlightID
        l.selection.backgroundColor = windowActive ? palette.selectionActive : palette.selectionInactive
        let ar = SidebarDraw.tileAvatar(metrics)
        // The avatar: one bitmap at the largest pin size, scaled to the current one.
        l.avatar.frame = ar
        l.avatar.minificationFilter = .trilinear
        if l.avatarSpec != c.avatar || l.avatarGeneration != generation {
            l.avatar.contents = avatars.image(c.avatar, diameter: SidebarMetrics.pinMaxAvatar, ctx: renderContext)
            l.avatarSpec = c.avatar; l.avatarGeneration = generation
        }
        configureSenders(l, c, avatar: ar)
        l.dot.isHidden = !c.unread
        l.dot.cornerRadius = 6
        l.dot.backgroundColor = palette.unread
        if c.typing {
            l.setTyping(palette, scale: s)
            l.typing?.showsTail = true
            // Where the unread message bubble goes: centered over the avatar's top (to verify).
            l.typing?.position = CGPoint(x: ar.midX, y: ar.minY + ar.height * 0.30 - SidebarTypingLayer.size.height / 2)
            if let t = l.typing, typingAppeared.remove(c.id) != nil { SidebarMotion.typingIn(t) }
        } else {
            l.setTyping(nil)
        }
        if metrics.compact {
            l.content.isHidden = true
            l.time.isHidden = true
        } else {
            let keys = SidebarController.tileKeys(c, natural: natural(c), tileWidth: metrics.tileWidth, emphasized: emphasized(i), generation: generation)
            let name = tileImage(keys.name, c)
            let nw = CGFloat(name?.width ?? 0) / s // an unallocated name shows nothing
            l.content.isHidden = false
            l.content.contents = name
            l.content.frame = CGRect(x: ((f.width - nw) / 2).rounded(), y: ar.maxY + SidebarMetrics.pinNameGap, width: nw, height: SidebarMetrics.pinNameHeight)
            if let bk = keys.bubble, let b = tileImage(bk, c) { // an unallocated bubble is not shown
                // The newest unread message over the avatar's top (the typing bubble, a layer,
                // takes its place while someone types).
                let bw = CGFloat(b.width) / s, bh = CGFloat(b.height) / s
                let bottom = ar.minY + ar.height * 0.30
                l.time.isHidden = false
                l.time.contents = b
                l.time.frame = CGRect(x: ((f.width - (bw - 1)) / 2).rounded() - 1, y: max(1, bottom - (bh - 5)), width: bw, height: bh)
            } else {
                l.time.isHidden = true
            }
        }
        // The unread dot on the tile's leading edge, below the bubble when one shows, so a wide
        // bubble never covers it (SidebarDraw.tileUnreadDot; the bubble rect without its tail).
        let bubble = l.time.isHidden || metrics.compact ? nil
            : CGRect(x: l.time.frame.minX + 1, y: l.time.frame.minY, width: l.time.frame.width - 1, height: l.time.frame.height - 5)
        l.dot.frame = SidebarDraw.tileUnreadDot(metrics, bubble: bubble)
        // Configured for this width (the stale check compares it).
        l.shownKey = SidebarBitmapKey(kind: .tile, id: c.id, version: c.version, width: metrics.tileWidth, emphasized: false, generation: generation)
        l.contentsScaleAll(s)
    }

    /// Up to 3 recent senders of a pinned group, each a small avatar on the group avatar's edge
    /// (lower left, lower right, upper right), ringed in the list's background. Geometry UNVERIFIED.
    private func configureSenders(_ l: SidebarRowLayer, _ c: ConversationSummary, avatar ar: CGRect) {
        let ids = c.isGroup && !metrics.compact ? Array(c.recentSenders.prefix(3)) : []
        let specs = ids.compactMap { id in c.participants.first { $0.id == id }?.avatar }
        while l.senders.count > specs.count { l.senders.removeLast().removeFromSuperlayer() }
        while l.senders.count < specs.count {
            let s = CALayer()
            s.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "borderColor": NSNull()]
            s.contentsGravity = .resize
            s.minificationFilter = .trilinear
            l.addSublayer(s)
            l.senders.append(s)
        }
        let d = SidebarDraw.senderDiameter(avatar: ar.width)
        for (k, (spec, s)) in zip(specs, l.senders).enumerated() { // no index math
            s.frame = SidebarDraw.senderRect(k, avatar: ar, diameter: d)
            s.cornerRadius = d / 2
            s.borderWidth = 1.5
            s.borderColor = palette.senderRing
            s.contents = avatars.image(spec, diameter: SidebarMetrics.pinMaxAvatar * 0.32, ctx: renderContext)
            s.contentsScale = renderContext.scale
        }
    }
    /// A tile's recent-sender avatars (tests): their frames in tile coordinates.
    func tileSenders(_ t: Int) -> [CGRect] { tileLayers[checked: t]?.senders.map(\.frame) ?? [] } // checked

    // MARK: Selection

    /// Selects a conversation. `notify`: tell the delegate (user actions); `reveal`: scroll it
    /// into view.
    func select(_ id: ConversationID?, notify: Bool = true, reveal: Bool = true) {
        highlight(id, notify: notify, reveal: reveal)
    }

    /// Moves the highlight to a conversation or an extra result. `notify`: a conversation goes
    /// to the delegate's `didSelect`, an extra result to the search provider.
    func highlight(_ id: ConversationID?, notify: Bool = true, reveal: Bool = true) {
        guard id != highlightID else { return }
        let t0 = beginWork()
        defer { endWork(t0) }
        let old = highlightID
        highlightID = id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for changed in [old, id].compactMap({ $0 }) { refresh(changed) }
        // The separators of the rows above the old and new selection.
        for changed in [old, id].compactMap({ $0 }) {
            if case let .row(r)? = position(of: changed), r > 0, let l = rowLayers[r - 1] { configure(l, row: r - 1, sync: true) }
        }
        CATransaction.commit()
        if reveal, let id, let p = position(of: id) { _ = document.scrollToVisible(rect(p).insetBy(dx: 0, dy: -2)) }
        updateAccessibility()
        guard notify else { return }
        if let id, Self.isExtra(id) {
            searchProvider?.sidebar(self, didSelectSearchResult: Self.hostID(id))
        } else {
            delegate?.sidebar(self, didSelect: id)
        }
    }

    /// Redraws one conversation's row or tile (selection, data change).
    private func refresh(_ id: ConversationID) {
        switch position(of: id) {
        case let .tile(t)?: configureTile(t)
        case let .row(r)?: if let l = rowLayers[r] { configure(l, row: r, sync: true) }
        case nil: break
        }
    }

    /// Up/down: pinned tiles in order, then the rows.
    func moveSelection(_ delta: Int) {
        let order = pinnedItems.count + rowItems.count
        guard order > 0 else { return }
        var cur = -1
        if let id = highlightID, let p = position(of: id) {
            switch p { case let .tile(t): cur = t; case let .row(r): cur = pinnedItems.count + r }
        }
        let next = cur < 0 ? (delta > 0 ? 0 : order - 1) : min(order - 1, max(0, cur + delta))
        guard next != cur else { return }
        guard let i = next < pinnedItems.count ? pinnedItems[checked: next] : rowItems[checked: next - pinnedItems.count],
              let c = snapshot.items[checked: i] else { return }
        highlight(c.id)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { setQuery(searchField.stringValue) }

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        extraRequest?.cancel()
        extraRequest = nil
        if extraSection?.query != trimmed { extraSection = nil }
        runSearch(trimmed)
        if !trimmed.isEmpty, let provider = searchProvider {
            let request = SidebarSearchRequest(query: trimmed) { [weak self] section in
                DispatchQueue.main.async { self?.extraResults(section, for: trimmed) }
            }
            extraRequest = request
            provider.sidebar(self, search: request)
        }
    }

    /// The provider answered: the section joins the current query's results (built and
    /// rendered on the search queue like any result).
    private func extraResults(_ section: SidebarSearchSection?, for q: String) {
        guard q == query else { return }
        extraRequest = nil
        let s = section.flatMap { $0.results.isEmpty ? nil : $0 }
        guard s != extraSection?.section || (s != nil && extraSection == nil) else { return }
        extraSection = s.map { (q, $0) }
        runSearch(q)
    }

    /// Filters off the main thread (an empty query: the full list again); the newest query
    /// wins (older ones stop early). The search queue also renders the first screen of the
    /// result (rows and pinned tiles the cache lacks), so applying it on the main thread draws
    /// nothing there.
    private func runSearch(_ q: String) {
        searchGeneration += 1
        let gen = searchGeneration
        stale.set(gen)
        let snap = baseSnapshot, index = baseIndex
        let extras = q.isEmpty ? nil : extraSection.flatMap { $0.query == q ? $0.section : nil }
        let existing = searchIndex
        let stale = stale
        let prerender = prerenderer()
        let filterNow = filter
        searchQueue.async { [weak self] in
            let idx: ConversationSearchIndex? = q.isEmpty ? nil : existing ?? ConversationSearchIndex(snap)
            var list: RowList
            var shown = snap, shownIndex = index
            if let idx {
                guard var m = idx.matches(q, cancelled: { stale.get() != gen }) else { return }
                m = m.filter { snap.items[checked: $0].map(filterNow.includes) ?? false } // checked
                if let extras {
                    // The host's rows after the conversations, as summaries of their own.
                    let start = m.count
                    for r in extras.results {
                        var c = ConversationSummary(id: SidebarController.extraID(r.id), title: r.title, participants: [], avatar: r.avatar,
                                                    preview: r.subtitle, previewSender: nil, lastAt: .distantPast, unreadCount: 0,
                                                    pinned: false, muted: false, typing: false, lastReaction: nil)
                        var h = Hasher(); h.combine(r.title); h.combine(r.subtitle); h.combine(r.avatar)
                        c.version = h.finalize()
                        guard !shownIndex.keys.contains(c.id) else { continue } // dictionary spelled apart from index subscripts
                        shownIndex.updateValue(shown.items.count, forKey: c.id)
                        m.append(shown.items.count)
                        shown.items.append(c)
                    }
                    list = RowList(pinned: [], rows: m, count: shown.items.count, searching: true)
                    if m.count > start { list.extraStart = start; list.extraTitle = extras.title }
                } else {
                    list = RowList(pinned: [], rows: m, count: snap.items.count, searching: true)
                }
            } else {
                list = RowList.full(snap, index, filter: filterNow)
            }
            guard stale.get() == gen else { return }
            let images = prerender(shown, list)
            DispatchQueue.main.async {
                guard let self, gen == self.searchGeneration else { return }
                if self.searchIndex == nil, let idx { self.searchIndex = idx }
                self.snapshot = shown
                self.indexByID = shownIndex
                self.insert(images)
                self.applyRows(list)
                self.searchApplied?(q, list.rows.count)
            }
        }
    }

    /// Bitmaps rendered off the main thread for a list about to be applied.
    private struct Prerendered {
        var rows: [(key: SidebarBitmapKey, time: CGImage, text: CGImage)] = []
        var tiles: [(key: SidebarBitmapKey, image: CGImage)] = []
    }

    /// A function (any thread) that renders the bitmaps a list needs on its first screen and
    /// the cache lacks now: the visible rows at the current scroll position and at the top,
    /// and the pinned tiles. Values only; read on the main thread when the search starts.
    private func prerenderer() -> (ConversationListSnapshot, RowList) -> Prerendered {
        let ctx = renderContext, job = rowJob(), avatars = avatars
        let cached = cache.keys
        let selected = windowActive ? highlightID : nil
        let clip = scrollView.contentView.bounds
        let rh = SidebarMetrics.rowHeight
        let m = ctx.metrics
        return { snap, list in
            func key(_ kind: SidebarBitmapKey.Kind, _ c: ConversationSummary) -> SidebarBitmapKey {
                SidebarBitmapKey(kind: kind, id: c.id, version: c.version, width: kind == .row ? m.width : m.tileWidth,
                                 emphasized: c.id == selected, generation: ctx.generation)
            }
            // The rows tile() will show once the list is applied: at the top, and at the scroll
            // position as the clip view will clamp it to the new document (a shorter result list
            // pulls a scrolled clip up to its end), with tile()'s own row arithmetic.
            let ph = m.pinnedHeight(count: list.pinned.count)
            let header = list.extraStart != nil ? SidebarController.sectionHeaderHeight : 0
            let docHeight = max(ph + CGFloat(list.rows.count) * rh + header + 8, clip.height)
            func position(_ y: CGFloat) -> CGFloat {
                var d = y - ph
                if let e = list.extraStart, d > CGFloat(e) * rh { d = max(CGFloat(e) * rh, d - header) }
                return d / rh
            }
            var rows = Set<Int>()
            for top in [0, min(clip.minY, docHeight - clip.height)] {
                // no trap on NaN or a huge position (CrashGuard.int).
                let first = max(0, CrashGuard.int(position(top).rounded(.down), in: CrashGuard.rowRange))
                let last = min(list.rows.count, CrashGuard.int(position(top + clip.height).rounded(.up), in: CrashGuard.rowRange))
                if first < last { for r in first..<last { rows.insert(r) } }
            }
            // Row avatars too (the avatar cache is locked): a result row whose avatar is not
            // drawn yet would draw it on the main thread.
            let screenItems = rows.compactMap { r in list.rows[checked: r].flatMap { i in snap.items[checked: i] } } // checked
            DispatchQueue.concurrentPerform(iterations: screenItems.count) { j in
                if let item = screenItems[checked: j] { _ = avatars.image(item.avatar, diameter: SidebarMetrics.avatar, ctx: ctx) }
            }
            let rowWork = screenItems.map { (key(.row, $0), $0) }.filter { !cached.contains($0.0) }
            let tileWork: [(SidebarBitmapKey, ConversationSummary)] = m.compact ? [] : list.pinned.compactMap { snap.items[checked: $0] }.flatMap { c -> [(SidebarBitmapKey, ConversationSummary)] in // checked
                let k = SidebarController.tileKeys(c, natural: SidebarDraw.tileNatural(c), tileWidth: m.tileWidth, emphasized: c.id == selected, generation: ctx.generation)
                return [k.name, k.bubble].compactMap { $0 }.map { ($0, c) }
            }.filter { !cached.contains($0.0) }
            var out = Prerendered()
            guard !m.compact || !tileWork.isEmpty else { return out }
            let n = (m.compact ? 0 : rowWork.count) + tileWork.count
            var rowsOut = [(time: CGImage, text: CGImage?, layout: SidebarDraw.RowTextLayout)?](repeating: nil, count: rowWork.count)
            var tilesOut = [CGImage?](repeating: nil, count: tileWork.count)
            rowsOut.withUnsafeMutableBufferPointer { ro in
                tilesOut.withUnsafeMutableBufferPointer { to in
                    DispatchQueue.concurrentPerform(iterations: n) { j in
                        if j < tileWork.count { // checked (unsafe buffers do not check)
                            if let w = tileWork[checked: j], let slot = to.checkedIndex(j) { to[slot] = SidebarController.tilePart(w.0, w.1, ctx) }
                        } else {
                            if let w = rowWork[checked: j - tileWork.count], let slot = ro.checkedIndex(j - tileWork.count) { ro[slot] = job(w.1, w.0, nil, nil) }
                        }
                    }
                }
            }
            for (w, result) in zip(rowWork, rowsOut) { if let r = result, let text = r.text { out.rows.append((w.0, r.time, text)) } }
            for (w, image) in zip(tileWork, tilesOut) { if let img = image { out.tiles.append((w.0, img)) } }
            return out
        }
    }

    /// Puts prerendered bitmaps in the cache (those of an older width or palette are dropped).
    private func insert(_ p: Prerendered) {
        let t0 = beginWork()
        defer { endWork(t0) }
        for r in p.rows where r.key.generation == generation && r.key.width == metrics.width && !cache.contains(r.key) {
            cache.insert(timeKey(r.key), r.time)
            cache.insert(r.key, r.text)
        }
        for t in p.tiles where t.key.generation == generation && !cache.contains(t.key) {
            cache.insert(t.key, t.image)
            stats.tiles += 1
        }
    }
    /// The newest query's generation, read by the search queue (a newer query stops an older one).
    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let stale = Generation()
    /// Search results applied (bench and self-test).
    var searchApplied: ((String, Int) -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if highlightID.map({ position(of: $0) == nil }) ?? true { moveSelection(1) } // no force unwrap
            view.window?.makeFirstResponder(document)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            setQuery("")
            view.window?.makeFirstResponder(document)
            return true
        default: return false
        }
    }

    // MARK: Context menu

    private var menuTarget: ConversationID?
    func menu(at p: CGPoint) -> NSMenu? {
        guard let h = hit(p), let c = summary(h) else { return nil } // a stale hit has no menu
        // The host's extra search rows have no menu.
        guard !Self.isExtra(c.id) else { return nil }
        menuTarget = c.id
        let m = NSMenu()
        // The controller hears the close (menuDidClose hides the target ring and clears menuTitles).
        m.delegate = self
        let actions = delegate?.sidebar(self, actionsFor: c.id) ?? []
        let extra = delegate?.sidebar(self, menuItemsFor: c.id) ?? []
        func add(_ title: String, _ sel: Selector) { let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; m.addItem(it) }
        if actions.contains(.pin) { add(c.pinned ? SidebarStrings.unpin : SidebarStrings.pin, #selector(togglePin)) }
        if actions.contains(.markRead) { add(c.unread ? SidebarStrings.markRead : SidebarStrings.markUnread, #selector(toggleRead)) }
        if actions.contains(.mute) { add(c.muted ? SidebarStrings.showAlerts : SidebarStrings.hideAlerts, #selector(toggleMute)) }
        if !extra.isEmpty {
            if m.numberOfItems > 0 { m.addItem(.separator()) }
            extra.forEach(m.addItem)
        }
        if actions.contains(.delete) {
            if m.numberOfItems > 0 { m.addItem(.separator()) }
            add(SidebarStrings.delete, #selector(deleteConversation))
        }
        guard m.numberOfItems > 0 else { menuTarget = nil; return nil }
        menuTitles = m.items.map(\.title)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        menuRing.frame = rect(h)
        menuRing.cornerRadius = { if case .tile = h { return SidebarMetrics.pinSelectionRadius }; return SidebarMetrics.selectionRadius }()
        menuRing.borderColor = palette.accent
        menuRing.isHidden = false
        CATransaction.commit()
        return m
    }
    /// The open menu's item titles (tests; empty when no menu is open).
    private(set) var menuTitles: [String] = []
    func menuDidClose(_ menu: NSMenu) {
        menuTitles = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        menuRing.isHidden = true
        CATransaction.commit()
    }
    @objc private func togglePin() { if let id = menuTarget, let c = summary(id) { setPinned(!c.pinned, id) } }
    /// Pin or unpin through the delegate (the menu's action; also the self-test's).
    func setPinned(_ pinned: Bool, _ id: ConversationID) { delegate?.sidebar(self, setPinned: pinned, for: id) }
    @objc private func toggleRead() { if let id = menuTarget, let c = summary(id) { delegate?.sidebar(self, setRead: c.unread, for: id) } }
    @objc private func toggleMute() { if let id = menuTarget, let c = summary(id) { delegate?.sidebar(self, setMuted: !c.muted, for: id) } }
    @objc private func deleteConversation() { if let id = menuTarget { delegate?.sidebar(self, delete: id) } }

    // MARK: Appearance and window state

    func appearanceChanged() {
        let p = resolvePalette()
        guard p != palette || bellSecondary == nil else { return }
        palette = p
        bellSecondary = Self.bell(NSColor.secondaryLabelColor, view.effectiveAppearance, scale: renderContext.scale)
        bellSelected = Self.bell(NSColor.white, view.effectiveAppearance, scale: renderContext.scale)
        // Not delivered: systemRed exclamationmark.circle.fill, 12 pt (size and place to verify).
        failedGlyph = Self.symbol("exclamationmark.circle.fill", size: 12, NSColor.systemRed, view.effectiveAppearance, scale: renderContext.scale)
        failedSelected = Self.symbol("exclamationmark.circle.fill", size: 12, NSColor.white, view.effectiveAppearance, scale: renderContext.scale)
        invalidateAll()
    }
    private func colorsChanged() {  // no selector
        guard isViewLoaded else { return }
        palette = resolvePalette()
        invalidateAll()
    }
    private func resolvePalette() -> SidebarPalette {
        SidebarPalette.resolve(view.effectiveAppearance, unreadColor: unreadColor, selectionColor: selectionColor)
    }
    func scaleChanged() { avatars.removeAll(); invalidateAll() }
    func setWindowActive(_ active: Bool) {
        guard active != windowActive else { return }
        windowActive = active
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let id = highlightID { refresh(id) }
        CATransaction.commit()
    }

    /// Drops every bitmap and redraws the visible ones.
    func invalidateAll() {
        generation += 1
        cache.removeAll()
        textCache.removeAll()
        pending.removeAll()
        for l in rowLayers.values + tileLayers { l.shownKey = nil }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in tileLayers.indices where t < pinnedItems.count { configureTile(t) }
        CATransaction.commit()
        layoutSectionHeader()
        tile(force: true)
    }

    static func bell(_ color: NSColor, _ appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        symbol("bell.slash.fill", size: 9, color, appearance, scale: scale)
    }
    /// An SF Symbol tinted in one color, as a bitmap at the window's scale (main thread).
    static func symbol(_ name: String, size: CGFloat, _ color: NSColor, _ appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))) else { return nil }
        var img: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let r = NSRect(origin: .zero, size: sym.size)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: CrashGuard.int(sym.size.width * scale), pixelsHigh: CrashGuard.int(sym.size.height * scale),

                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = sym.size
            if let rep, let g = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = g
                sym.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
                img = rep.cgImage
            }
        }
        return img
    }

    // MARK: Accessibility

    /// The elements are built when an assistive client asks (never per scroll frame).
    private var accessibilityCache: [NSAccessibilityElement]?
    private func updateAccessibility() { accessibilityCache = nil }
    func accessibilityElements() -> [NSAccessibilityElement] {
        if let c = accessibilityCache { return c }
        let e = buildAccessibility()
        accessibilityCache = e
        return e
    }

    /// One element per pinned tile and visible row (the rows are layers).
    private func buildAccessibility() -> [NSAccessibilityElement] {
        var out: [NSAccessibilityElement] = []
        func element(_ h: Hit) -> NSAccessibilityElement? { // nil for a stale hit
            guard let c = summary(h) else { return nil }
            let e = SidebarAccessibilityRow(controller: self, id: c.id)
            e.setAccessibilityRole(.row)
            var parts = [c.title]
            if c.typing { parts.append(SidebarStrings.typing) } else { parts.append(SidebarStrings.preview(c)) }
            if !Self.isExtra(c.id) { parts.append(timeFormatter.string(c.lastAt, now: now())) }
            if c.unread { parts.append(String(format: SidebarStrings.unreadFormat, c.unreadCount)) }
            if c.failed { parts.append(SidebarStrings.notDelivered) }
            if c.muted { parts.append(SidebarStrings.muted) }
            if c.pinned { parts.append(SidebarStrings.pinned) }
            e.setAccessibilityLabel(parts.joined(separator: ", "))
            e.setAccessibilityTitle(c.title)
            e.setAccessibilitySelected(c.id == highlightID)
            e.setAccessibilityParent(document)
            return e
        }
        for t in pinnedItems.indices { if let e = element(.tile(t)) { out.append(e) } }
        for r in lastVisible where r < rowItems.count { if let e = element(.row(r)) { out.append(e) } }
        return out
    }
}

/// A list row's accessibility element: press selects it.
final class SidebarAccessibilityRow: NSAccessibilityElement {
    weak var controller: SidebarController?
    let id: ConversationID
    init(controller: SidebarController, id: ConversationID) { self.controller = controller; self.id = id; super.init() }
    override func accessibilityPerformPress() -> Bool { controller?.highlight(id); return true }
    override func isAccessibilityElement() -> Bool { true }
    /// On screen, from the list's own (flipped) geometry at the time of the call: a frame in
    /// parent space came out mirrored on the list's height (dogfood 2026-10-08: rows at y 28590).
    override func accessibilityFrame() -> NSRect { controller?.screenRect(of: id) ?? .zero }
}

/// One row or tile: selection background, bitmap content, separator, typing bubble.
final class SidebarRowLayer: CALayer {
    let selection = CALayer()
    let avatar = CALayer()
    let dot = CALayer()
    /// The text bitmap (name and preview) for rows; the whole tile bitmap for pinned tiles.
    let content = CALayer()
    let time = CALayer()
    let separator = CALayer()
    private(set) var typing: SidebarTypingLayer?
    /// A pinned group tile's recent senders (small avatars at the avatar's edge).
    var senders: [CALayer] = []
    /// The conversation this layer shows (nil: in the pool).
    var conversationID: ConversationID?
    var shownKey: SidebarBitmapKey?
    /// The line breaks and truncation of the text bitmap on screen (nil: not known, e.g. from the cache).
    var shownLayout: SidebarDraw.RowTextLayout?
    /// The text bitmap show() put in `content` (with `shownLayout`).
    var shownText: CGImage?
    var avatarSpec: AvatarSpec?
    var avatarGeneration = -1
    override init() {
        super.init()
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull(),
                                        "backgroundColor": NSNull(), "frame": NSNull(), "cornerRadius": NSNull()]
        actions = none
        for l in [selection, avatar, dot, content, time, separator] { l.actions = none; addSublayer(l) }
        content.contentsGravity = .topLeft
        time.contentsGravity = .topLeft
        avatar.contentsGravity = .resize
        dot.isHidden = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
    /// Hands the typing bubble to the caller (it fades it out elsewhere); the row has none after.
    func detachTyping() -> SidebarTypingLayer? { let t = typing; typing = nil; return t }
    func setTyping(_ p: SidebarPalette?, scale: CGFloat = 2) {
        guard let p else { typing?.removeFromSuperlayer(); typing = nil; return }
        if typing == nil { let t = SidebarTypingLayer(); addSublayer(t); typing = t }
        typing?.apply(p, scale: scale)
        typing?.animate()
    }
    func contentsScaleAll(_ s: CGFloat) {
        guard content.contentsScale != s else { return }
        for l in [self, selection, avatar, dot, content, time, separator] { l.contentsScale = s }
    }
}

/// The scroll view's document: flipped, layer-backed with no drawing of its own (rows are
/// sublayers), takes clicks, keys and the context menu.
final class SidebarDocumentView: NSView {
    weak var controller: SidebarController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(SidebarStrings.conversations)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityChildren() -> [Any]? { controller?.accessibilityElements() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    /// A horizontal two-finger swipe on a row is the row's swipe; anything else scrolls.
    private var swiping = false
    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return super.scrollWheel(with: event) }
        let p = point(event)
        if event.phase == .began, event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            swiping = c.swipe(.began, dx: event.scrollingDeltaX, at: p)
            if swiping { return }
        }
        if swiping {
            if event.phase == .changed { c.swipe(.changed, dx: event.scrollingDeltaX, at: p) }
            else if event.phase == .ended || event.phase == .cancelled { c.swipe(event.phase == .ended ? .ended : .cancelled, dx: 0, at: p); swiping = false }
            return
        }
        // The swipe's momentum and a vertical scroll close an open row.
        if !event.momentumPhase.isEmpty, c.swipeState != nil, event.phase.isEmpty { return }
        if c.swipeState != nil, event.phase == .began { _ = c.swipeClick(at: CGPoint(x: -1, y: -1)) }
        super.scrollWheel(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let c = controller, c.swipeClick(at: point(event)) { return }
        guard let c = controller, let h = c.hit(point(event)), let s = c.summary(h) else { return } // a stale hit selects nothing
        c.highlight(s.id, reveal: false)
        // cmux: press and drag a tile or row (Cmux/SidebarPinDragging.swift: reorder, pin and unpin
        // by drag, Escape cancels), a superset of MessagesLab's tile reorder (tileDragBegan).
        c.trackPinDrag(from: event, in: self)
    }
    override func mouseDragged(with event: NSEvent) { controller?.tileDragMoved(to: point(event)) }
    override func mouseUp(with event: NSEvent) { controller?.tileDragEnded(at: point(event)) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(at: point(event)) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: controller?.moveSelection(1)
        case 126: controller?.moveSelection(-1)
        default: interpretKeyEvents([event])
        }
    }
    override func cancelOperation(_ sender: Any?) { controller?.cancelPinDrag() } // cmux: Escape reaching the list ends a pin drag
    override func moveDown(_ sender: Any?) { controller?.moveSelection(1) }
    override func moveUp(_ sender: Any?) { controller?.moveSelection(-1) }
    /// Typing a letter in the list starts a search (as a source list's type-select would).
    override func insertText(_ insertString: Any) {
        guard let s = insertString as? String, let c = controller else { return }
        window?.makeFirstResponder(c.searchField)
        c.searchField.stringValue += s
        c.searchField.currentEditor()?.moveToEndOfDocument(nil)
        c.setQuery(c.searchField.stringValue)
    }
    @objc func performFind(_ sender: Any?) { if let c = controller { window?.makeFirstResponder(c.searchField) } }

    // No hover: Messages draws none on rows or tiles (no tracking area).
}

/// The sidebar's root view: lays out the search field and the list; follows the window's
/// key state, appearance and scale.
final class SidebarRootView: NSView {
    weak var controller: SidebarController?
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        controller?.layout(in: bounds)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let w = window else { return }
        let nc = NotificationCenter.default
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                self?.controller?.setWindowActive(w.isKeyWindow)
            })
        }
        controller?.setWindowActive(w.isKeyWindow || ProcessInfo.processInfo.arguments.contains("--active"))
        controller?.appearanceChanged()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.appearanceChanged()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.scaleChanged()
    }
}

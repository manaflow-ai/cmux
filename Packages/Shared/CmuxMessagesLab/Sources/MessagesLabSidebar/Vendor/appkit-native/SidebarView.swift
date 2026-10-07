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
    /// The selected conversation (nil: none).
    private(set) var selectedID: ConversationID?

    let searchField = NSSearchField()
    let scrollView = NSScrollView()
    let document = SidebarDocumentView()

    // Data.
    private(set) var snapshot = ConversationListSnapshot(items: [], pinned: [])
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
    private var palette = SidebarPalette.resolve(NSAppearance(named: .darkAqua)!)
    private var generation = 0
    private var scale: CGFloat { document.window?.backingScaleFactor ?? 2 }
    private let cache = SidebarBitmapCache()
    private let avatars = SidebarAvatarCache()
    private let textCache = SidebarTextCache()
    private let timeFormatter = ConversationTimeFormatter(yesterday: SidebarStrings.yesterday)
    private var bellSecondary: CGImage?, bellSelected: CGImage?
    private var windowActive = true
    private var pending: Set<SidebarBitmapKey> = []
    private var rowLayers: [Int: SidebarRowLayer] = [:]
    private var pool: [SidebarRowLayer] = []
    private var tileLayers: [SidebarRowLayer] = []
    private let hoverLayer = CALayer()
    private let menuRing = CALayer()
    private var hovered: Hit?
    private var lastVisible: Range<Int> = 0..<0
    private var lastTop: CGFloat = 0
    let noResults = NSTextField(labelWithString: "")

    /// Counters for the bench and the self-test.
    struct Stats { var syncRenders = 0; var asyncRenders = 0; var layersCreated = 0; var tiles = 0
        /// Main-thread time in the list's own tiling, layout and selection (ms, cumulative).
        var workMs = 0.0 }
    private(set) var stats = Stats()
    var rowLayerCount: Int { rowLayers.count }
    var visibleRowRange: Range<Int> { lastVisible }

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

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        document.controller = self
        root.addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)

        hoverLayer.cornerRadius = SidebarMetrics.selectionRadius
        hoverLayer.isHidden = true
        hoverLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        hoverLayer.zPosition = -1
        menuRing.cornerRadius = SidebarMetrics.selectionRadius
        menuRing.borderWidth = 2
        menuRing.isHidden = true
        menuRing.zPosition = 5
        menuRing.actions = hoverLayer.actions
        document.layer?.addSublayer(hoverLayer)
        document.layer?.addSublayer(menuRing)

        noResults.stringValue = SidebarStrings.noResults
        noResults.font = .systemFont(ofSize: 15, weight: .semibold)
        noResults.textColor = .secondaryLabelColor
        noResults.alignment = .center
        noResults.isHidden = true
        root.addSubview(noResults)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Data

    /// Reads the data source again and redraws what changed (bitmaps are keyed by id and
    /// version, so unchanged rows keep theirs).
    func reloadData() {
        _ = view
        snapshot = dataSource?.sidebarSnapshot(self) ?? ConversationListSnapshot(items: [], pinned: [])
        var map: [ConversationID: Int] = [:]
        map.reserveCapacity(snapshot.items.count)
        for (i, c) in snapshot.items.enumerated() { map[c.id] = i }
        indexByID = map
        searchIndex = nil
        if query.isEmpty {
            applyRows(nil)
        } else {
            runSearch(query)
        }
    }

    func summary(_ id: ConversationID) -> ConversationSummary? { indexByID[id].map { snapshot.items[$0] } }

    /// `matches`: item indices of a search, nil for the full list (pinned grid + rows).
    private func applyRows(_ matches: [Int]?) {
        let t0 = beginWork()
        defer { endWork(t0) }
        if let matches {
            pinnedItems = []
            rowItems = matches
        } else {
            pinnedItems = snapshot.pinned.compactMap { indexByID[$0] }
            let p = Set(pinnedItems)
            rowItems = snapshot.items.indices.filter { !p.contains($0) }
        }
        rowOfItem = [Int32](repeating: -1, count: snapshot.items.count)
        for (r, i) in rowItems.enumerated() { rowOfItem[i] = Int32(r) }
        noResults.isHidden = !(matches != nil && matches!.isEmpty)
        for (_, l) in rowLayers { recycle(l) }
        rowLayers.removeAll()
        lastVisible = 0..<0
        rebuildTiles()
        layoutDocument()
        tile(force: true)
        updateAccessibility()
    }

    // MARK: Geometry

    var pinnedHeight: CGFloat { metrics.pinnedHeight(count: pinnedItems.count) }
    func rowRect(_ r: Int) -> CGRect {
        CGRect(x: 0, y: pinnedHeight + CGFloat(r) * SidebarMetrics.rowHeight, width: metrics.width, height: SidebarMetrics.rowHeight)
    }
    func selectionRect(_ r: Int) -> CGRect { rowRect(r).insetBy(dx: SidebarMetrics.selectionInsetX, dy: 0) }
    func tileRect(_ t: Int) -> CGRect { metrics.tileRect(t) }

    func hit(_ p: CGPoint) -> Hit? {
        if p.y < pinnedHeight {
            for t in pinnedItems.indices where tileRect(t).contains(p) { return .tile(t) }
            return nil
        }
        let r = Int((p.y - pinnedHeight) / SidebarMetrics.rowHeight)
        return r >= 0 && r < rowItems.count ? .row(r) : nil
    }
    func item(_ h: Hit) -> Int { switch h { case let .tile(t): return pinnedItems[t]; case let .row(r): return rowItems[r] } }
    func rect(_ h: Hit) -> CGRect {
        switch h { case let .tile(t): return tileRect(t).insetBy(dx: 2, dy: 2); case let .row(r): return selectionRect(r) }
    }
    /// Where a conversation is shown now (nil: filtered out).
    func position(of id: ConversationID) -> Hit? {
        guard let i = indexByID[id] else { return nil }
        if let t = pinnedItems.firstIndex(of: i) { return .tile(t) }
        let r = Int(rowOfItem[i])
        return r >= 0 ? .row(r) : nil
    }

    func layout(in bounds: CGRect) {
        let M = SidebarMetrics.self
        let top = M.titlebar
        searchField.frame = CGRect(x: M.searchInsetX, y: top, width: bounds.width - 2 * M.searchInsetX, height: M.searchHeight)
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
            rebuildTiles()
            layoutDocument()
            tile(force: true)
        }
    }

    private func layoutDocument() {
        let h = pinnedHeight + CGFloat(rowItems.count) * SidebarMetrics.rowHeight + 8
        let f = CGRect(x: 0, y: 0, width: metrics.width, height: max(h, scrollView.contentSize.height))
        if document.frame != f { document.frame = f }
    }

    // MARK: Tiling (O(visible))

    @objc private func clipMoved() { tile(force: false) }

    private var renderContext: SidebarRenderContext {
        SidebarRenderContext(metrics: metrics, palette: palette, scale: scale,
                             space: document.window?.screen?.colorSpace?.cgColorSpace ?? SidebarDraw.p3, generation: generation,
                             bellSecondary: bellSecondary, bellSelected: bellSelected, now: Date())
    }

    func key(_ kind: SidebarBitmapKey.Kind, item i: Int, emphasized: Bool) -> SidebarBitmapKey {
        let c = snapshot.items[i]
        return SidebarBitmapKey(kind: kind, id: c.id, version: c.version, width: kind == .row ? metrics.width : kind == .tile ? metrics.tileWidth : 0,
                                emphasized: emphasized, generation: generation)
    }
    private func emphasized(_ i: Int) -> Bool { windowActive && snapshot.items[i].id == selectedID }

    /// Lays out the rows the clip view shows, with a margin of a few rows; renders missing
    /// visible bitmaps now and the next screen's in the background.
    func tile(force: Bool) {
        guard !rowItems.isEmpty || !rowLayers.isEmpty else { return }
        let clip = scrollView.contentView.bounds
        let rh = SidebarMetrics.rowHeight
        let y0 = pinnedHeight
        let margin = 3
        let first = max(0, Int(((clip.minY - y0) / rh).rounded(.down)) - margin)
        let last = min(rowItems.count, Int(((clip.maxY - y0) / rh).rounded(.up)) + margin)
        let range = first < last ? first..<last : 0..<0
        let direction: CGFloat = clip.minY >= lastTop ? 1 : -1
        lastTop = clip.minY
        if !force, range == lastVisible { return }
        let t0 = beginWork()
        defer { endWork(t0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        batching = true
        for (r, l) in rowLayers where !range.contains(r) { recycle(l); rowLayers[r] = nil }
        let visible = Int(((clip.minY - y0) / rh).rounded(.down))..<Int(((clip.maxY - y0) / rh).rounded(.up))
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
        updateHover()
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
    private var batch: [(SidebarRowLayer, SidebarBitmapKey, ConversationSummary)] = []
    private func flushBatch() {
        batching = false
        guard !batch.isEmpty else { return }
        let work = batch
        batch.removeAll(keepingCapacity: true)
        let job = rowJob()
        var out = [(time: CGImage, text: CGImage)?](repeating: nil, count: work.count)
        let cachedTimes = work.map { cache.image(timeKey($0.1)) }
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: work.count) { j in o[j] = job(work[j].2, work[j].1, cachedTimes[j]) }
        }
        for (j, (l, k, _)) in work.enumerated() {
            guard let r = out[j] else { continue }
            stats.syncRenders += 1
            cache.insert(timeKey(k), r.time)
            cache.insert(k, r.text)
            show(l, k, time: r.time, text: r.text)
        }
    }

    /// Renders a row's time and text from values only (any thread).
    private func rowJob() -> (ConversationSummary, SidebarBitmapKey, CGImage?) -> (time: CGImage, text: CGImage) {
        let ctx = renderContext, time = timeFormatter, text = textCache
        return { c, k, cachedTime in
            let t = cachedTime ?? SidebarDraw.rowTime(c, emphasized: k.emphasized, ctx: ctx, time: time)
            let x = SidebarDraw.rowText(c, emphasized: k.emphasized, ctx: ctx, timeWidth: SidebarDraw.rowTimeWidth(t, scale: ctx.scale), text: text)
            return (t, x)
        }
    }
    private func timeKey(_ k: SidebarBitmapKey) -> SidebarBitmapKey {
        var t = k; t.kind = .time; t.width = 0; return t
    }
    private func show(_ l: SidebarRowLayer, _ k: SidebarBitmapKey, time: CGImage, text: CGImage) {
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
        l.shownKey = nil
        l.content.contents = nil
        l.time.contents = nil
        l.setTyping(nil)
        pool.append(l)
    }

    private func configure(_ l: SidebarRowLayer, row r: Int, sync: Bool) {
        let i = rowItems[r]
        let c = snapshot.items[i]
        let frame = rowRect(r)
        let selected = c.id == selectedID
        let k = key(.row, item: i, emphasized: emphasized(i))
        l.frame = frame
        l.content.frame = l.bounds
        l.selection.frame = CGRect(x: SidebarMetrics.selectionInsetX, y: 0, width: frame.width - 2 * SidebarMetrics.selectionInsetX, height: frame.height)
        l.selection.cornerRadius = SidebarMetrics.selectionRadius
        l.selection.isHidden = !selected
        l.selection.backgroundColor = windowActive ? palette.selectionActive : palette.selectionInactive
        // The separator under the text, hidden next to the selection (as NSTableView does).
        let nextSelected = r + 1 < rowItems.count && snapshot.items[rowItems[r + 1]].id == selectedID
        l.separator.isHidden = selected || nextSelected || r == rowItems.count - 1
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
        } else {
            l.setTyping(nil)
        }
        l.contentsScaleAll(renderContext.scale)
        if compact { l.shownKey = k; return }
        if l.shownKey == k { return }
        if let text = cache.image(k), let time = cache.image(timeKey(k)) {
            show(l, k, time: time, text: text)
        } else if sync, batching {
            // Drawn with the other visible rows of this pass, in parallel (flushBatch).
            l.shownKey = nil
            batch.append((l, k, c))
        } else if sync {
            let r = rowJob()(c, k, cache.image(timeKey(k)))
            stats.syncRenders += 1
            cache.insert(timeKey(k), r.time); cache.insert(k, r.text)
            show(l, k, time: r.time, text: r.text)
        } else {
            l.shownKey = nil
            request(k, item: i)
        }
    }

    /// Background render of a row's time and text; the result goes to whichever layer shows that key.
    private func request(_ k: SidebarBitmapKey, item i: Int) {
        guard !pending.contains(k), !cache.contains(k) else { return }
        pending.insert(k)
        let c = snapshot.items[i], job = rowJob(), cachedTime = cache.image(timeKey(k))
        renderQueue.async { [weak self] in
            let r = job(c, k, cachedTime)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(k)
                guard k.generation == self.generation, k.width == self.metrics.width else { return }
                self.stats.asyncRenders += 1
                self.cache.insert(self.timeKey(k), r.time)
                self.cache.insert(k, r.text)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                for (row, l) in self.rowLayers where l.shownKey == nil && row < self.rowItems.count
                    && self.key(.row, item: self.rowItems[row], emphasized: self.emphasized(self.rowItems[row])) == k {
                    self.show(l, k, time: r.time, text: r.text)
                }
                CATransaction.commit()
            }
        }
    }

    private func prefetch(from start: Int, direction: Int, count: Int) {
        var r = start
        for _ in 0..<count {
            guard r >= 0, r < rowItems.count else { return }
            let i = rowItems[r]
            let k = key(.row, item: i, emphasized: emphasized(i))
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
        // Tile bitmaps not in the cache: drawn in parallel first (a width change redraws all).
        let missing = pinnedItems.indices.filter { !cache.contains(key(.tile, item: pinnedItems[$0], emphasized: emphasized(pinnedItems[$0]))) }
        if missing.count > 1 {
            let ctx = renderContext, avatars = avatars
            let work = missing.map { (key(.tile, item: pinnedItems[$0], emphasized: emphasized(pinnedItems[$0])), snapshot.items[pinnedItems[$0]]) }
            var images = [CGImage?](repeating: nil, count: work.count)
            images.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: work.count) { j in
                    out[j] = SidebarDraw.tile(work[j].1, emphasized: work[j].0.emphasized, ctx: ctx, avatars: avatars)
                }
            }
            for (j, w) in work.enumerated() { if let img = images[j] { cache.insert(w.0, img); stats.tiles += 1 } }
        }
        for t in pinnedItems.indices { configureTile(t) }
        CATransaction.commit()
    }

    private func configureTile(_ t: Int) {
        let l = tileLayers[t], i = pinnedItems[t], c = snapshot.items[i]
        let f = tileRect(t)
        l.frame = f
        l.content.frame = l.bounds
        l.selection.frame = l.bounds.insetBy(dx: 2, dy: 2)
        l.selection.cornerRadius = SidebarMetrics.pinSelectionRadius
        l.selection.isHidden = c.id != selectedID
        l.selection.backgroundColor = windowActive ? palette.selectionActive : palette.selectionInactive
        let ar = SidebarDraw.tileAvatar(metrics)
        if c.typing {
            l.setTyping(palette, scale: renderContext.scale)
            // Where the unread message bubble goes: centered over the avatar's top (to verify).
            l.typing?.position = CGPoint(x: ar.midX, y: ar.minY + ar.height * 0.30 - SidebarTypingLayer.size.height / 2)
        } else {
            l.setTyping(nil)
        }
        let k = key(.tile, item: i, emphasized: emphasized(i))
        if l.shownKey != k {
            let img = cache.image(k) ?? {
                let img = SidebarDraw.tile(c, emphasized: k.emphasized, ctx: renderContext, avatars: avatars)
                stats.tiles += 1
                cache.insert(k, img)
                return img
            }()
            l.content.contents = img
            l.shownKey = k
        }
        l.contentsScaleAll(renderContext.scale)
    }

    // MARK: Selection

    /// Selects a conversation. `notify`: tell the delegate (user actions); `reveal`: scroll it
    /// into view.
    func select(_ id: ConversationID?, notify: Bool = true, reveal: Bool = true) {
        guard id != selectedID else { return }
        let t0 = beginWork()
        defer { endWork(t0) }
        let old = selectedID
        selectedID = id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for changed in [old, id].compactMap({ $0 }) { refresh(changed) }
        // The separators of the rows above the old and new selection.
        for changed in [old, id].compactMap({ $0 }) {
            if case let .row(r)? = position(of: changed), r > 0, let l = rowLayers[r - 1] { configure(l, row: r - 1, sync: true) }
        }
        CATransaction.commit()
        if reveal, let id, let p = position(of: id) { _ = document.scrollToVisible(rect(p).insetBy(dx: 0, dy: -2)) }
        updateHover()
        updateAccessibility()
        if notify { delegate?.sidebar(self, didSelect: id) }
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
        if let id = selectedID, let p = position(of: id) {
            switch p { case let .tile(t): cur = t; case let .row(r): cur = pinnedItems.count + r }
        }
        let next = cur < 0 ? (delta > 0 ? 0 : order - 1) : min(order - 1, max(0, cur + delta))
        guard next != cur else { return }
        let i = next < pinnedItems.count ? pinnedItems[next] : rowItems[next - pinnedItems.count]
        select(snapshot.items[i].id)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { setQuery(searchField.stringValue) }

    func setQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed != query else { return }
        query = trimmed
        if trimmed.isEmpty {
            searchGeneration += 1
            stale.set(searchGeneration)
            applyRows(nil)
        } else {
            runSearch(trimmed)
        }
    }

    /// Filters off the main thread; the newest query wins (older ones stop early).
    private func runSearch(_ q: String) {
        searchGeneration += 1
        let gen = searchGeneration
        stale.set(gen)
        let snap = snapshot
        let existing = searchIndex
        let stale = stale
        searchQueue.async { [weak self] in
            let idx = existing ?? ConversationSearchIndex(snap)
            let result = idx.matches(q) { stale.get() != gen }
            DispatchQueue.main.async {
                guard let self, gen == self.searchGeneration else { return }
                if self.searchIndex == nil { self.searchIndex = idx }
                guard let result else { return }
                self.applyRows(result)
                self.searchApplied?(q, result.count)
            }
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
            if selectedID == nil || position(of: selectedID!) == nil { moveSelection(1) }
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

    // MARK: Hover

    func mouseMoved(_ p: CGPoint?) {
        let h = p.flatMap(hit)
        guard h != hovered else { return }
        hovered = h
        updateHover()
    }
    private func updateHover() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let h = hovered, item(h) < snapshot.items.count, snapshot.items[item(h)].id != selectedID else { hoverLayer.isHidden = true; return }
        if case let .row(r) = h, r >= rowItems.count { hoverLayer.isHidden = true; return }
        if case let .tile(t) = h, t >= pinnedItems.count { hoverLayer.isHidden = true; return }
        hoverLayer.frame = rect(h)
        hoverLayer.cornerRadius = { if case .tile = h { return SidebarMetrics.pinSelectionRadius }; return SidebarMetrics.selectionRadius }()
        hoverLayer.backgroundColor = palette.hover
        hoverLayer.isHidden = false
    }

    // MARK: Context menu

    private var menuTarget: ConversationID?
    func menu(at p: CGPoint) -> NSMenu? {
        guard let h = hit(p) else { return nil }
        let c = snapshot.items[item(h)]
        menuTarget = c.id
        let m = NSMenu()
        m.delegate = self
        func add(_ title: String, _ sel: Selector) { let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; m.addItem(it) }
        add(c.pinned ? SidebarStrings.unpin : SidebarStrings.pin, #selector(togglePin))
        add(c.unread ? SidebarStrings.markRead : SidebarStrings.markUnread, #selector(toggleRead))
        add(c.muted ? SidebarStrings.showAlerts : SidebarStrings.hideAlerts, #selector(toggleMute))
        m.addItem(.separator())
        add(SidebarStrings.delete, #selector(deleteConversation))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        menuRing.frame = rect(h)
        menuRing.cornerRadius = { if case .tile = h { return SidebarMetrics.pinSelectionRadius }; return SidebarMetrics.selectionRadius }()
        menuRing.borderColor = palette.accent
        menuRing.isHidden = false
        CATransaction.commit()
        return m
    }
    func menuDidClose(_ menu: NSMenu) {
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
        let p = SidebarPalette.resolve(view.effectiveAppearance)
        guard p != palette || bellSecondary == nil else { return }
        palette = p
        bellSecondary = Self.bell(NSColor.secondaryLabelColor, view.effectiveAppearance, scale: renderContext.scale)
        bellSelected = Self.bell(NSColor.white, view.effectiveAppearance, scale: renderContext.scale)
        invalidateAll()
    }
    @objc private func colorsChanged() { palette = SidebarPalette.resolve(view.effectiveAppearance); invalidateAll() }
    func scaleChanged() { avatars.removeAll(); invalidateAll() }
    func setWindowActive(_ active: Bool) {
        guard active != windowActive else { return }
        windowActive = active
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let id = selectedID { refresh(id) }
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
        tile(force: true)
    }

    static func bell(_ color: NSColor, _ appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        guard let sym = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [color]))) else { return nil }
        var img: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let r = NSRect(origin: .zero, size: sym.size)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(sym.size.width * scale), pixelsHigh: Int(sym.size.height * scale),
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
        func element(_ h: Hit) -> NSAccessibilityElement {
            let c = snapshot.items[item(h)]
            let e = SidebarAccessibilityRow(controller: self, id: c.id)
            e.setAccessibilityRole(.row)
            var parts = [c.title]
            if c.typing { parts.append(SidebarStrings.typing) } else { parts.append(c.lastReaction.map(SidebarStrings.reaction) ?? c.preview) }
            parts.append(timeFormatter.string(c.lastAt))
            if c.unread { parts.append(String(format: SidebarStrings.unreadFormat, c.unreadCount)) }
            if c.muted { parts.append(SidebarStrings.muted) }
            if c.pinned { parts.append(SidebarStrings.pinned) }
            e.setAccessibilityLabel(parts.joined(separator: ", "))
            e.setAccessibilityTitle(c.title)
            e.setAccessibilitySelected(c.id == selectedID)
            e.setAccessibilityFrameInParentSpace(rect(h))
            e.setAccessibilityParent(document)
            return e
        }
        for t in pinnedItems.indices { out.append(element(.tile(t))) }
        for r in lastVisible where r < rowItems.count { out.append(element(.row(r))) }
        return out
    }
}

/// A list row's accessibility element: press selects it.
final class SidebarAccessibilityRow: NSAccessibilityElement {
    weak var controller: SidebarController?
    let id: ConversationID
    init(controller: SidebarController, id: ConversationID) { self.controller = controller; self.id = id; super.init() }
    override func accessibilityPerformPress() -> Bool { controller?.select(id); return true }
    override func isAccessibilityElement() -> Bool { true }
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
    var shownKey: SidebarBitmapKey?
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
/// sublayers), takes clicks, keys, hover and the context menu.
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
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = controller, let h = c.hit(point(event)) else { return }
        c.select(c.snapshot.items[c.item(h)].id, reveal: false)
    }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(at: point(event)) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: controller?.moveSelection(1)
        case 126: controller?.moveSelection(-1)
        default: interpretKeyEvents([event])
        }
    }
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

    // Hover: only while the window is key, only over the list.
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(point(event)) }
    override func mouseExited(with event: NSEvent) { controller?.mouseMoved(nil) }
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

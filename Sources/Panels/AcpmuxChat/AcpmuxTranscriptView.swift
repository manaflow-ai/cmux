import AppKit
import CmuxAcpmux
import QuartzCore

/// The virtualized chat transcript.
///
/// An `NSTableView` reuses two cell classes and asks ``AcpmuxRowLayoutEngine`` for
/// cached heights. Model changes only mark the view dirty; a display link applies at most
/// one diff per frame, so a fast stream of chunks costs one relayout of the growing row
/// per frame. The view stays pinned to the bottom until the user scrolls up, then counts
/// unread rows for the "jump to latest" pill. Scrolling near the top loads older history
/// and keeps the first visible row anchored so content does not jump.
@MainActor
final class AcpmuxTranscriptView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = AcpmuxTranscriptTableView()
    private let model: AcpmuxChatSessionModel
    private let engine: AcpmuxRowLayoutEngine
    private var rows: [TranscriptRow] = []
    private var positions: [AcpmuxRowGroupPosition] = []
    private var expandedRowIDs: Set<String> = []
    private var hiddenRowIDs: Set<String> = []
    private var displayLink: CADisplayLink?
    private var needsFlush = false
    private var isAdjustingScroll = false
    private var lastLayoutWidth: CGFloat = 0
    /// Rows measured exactly during the current height pass; other rows return estimates.
    private var measureWindow: Range<Int> = 0..<0
    /// Rows whose height is an estimate at the current width, refined a batch per frame.
    private var estimatedRows = IndexSet()
    private(set) var isPinnedToBottom = true
    private(set) var unreadCount = 0

    /// Called after a flush with the new unread count and pin state.
    var onScrollStateChanged: ((_ pinned: Bool, _ unread: Int) -> Void)?
    /// Called after a flush that laid out rows, so overlays can find row frames.
    var onDidFlush: (() -> Void)?
    /// Frame-flush timings in milliseconds, for the debug performance readout.
    private(set) var flushDurations: [Double] = []

    init(model: AcpmuxChatSessionModel, theme: AcpmuxChatTheme) {
        self.model = model
        self.engine = AcpmuxRowLayoutEngine(theme: theme)
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 10, right: 0)
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        tableView.dataSource = self
        tableView.delegate = self
        addSubview(scrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var theme: AcpmuxChatTheme { engine.theme }

    func setTheme(_ theme: AcpmuxChatTheme) {
        guard theme != engine.theme else { return }
        engine.setTheme(theme)
        tableView.reloadData()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = tableView.bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            relayoutForWidthChange()
        }
    }

    /// A width change measures only the rows on screen (plus a margin) now. Every other row
    /// gets a scaled estimate and is measured in small batches on later frames, so a live
    /// resize of a 5,000-row transcript costs a screenful of text layout per frame.
    private func relayoutForWidthChange() {
        let wasPinned = isPinnedToBottom
        let anchor = wasPinned ? nil : captureAnchor()
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        let lower = max(0, visible.location - 20)
        let upper = min(rows.count, visible.location + visible.length + 20)
        measureWindow = lower..<max(lower, upper)
        estimatedRows = IndexSet()
        isAdjustingScroll = true
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        isAdjustingScroll = false
        measureWindow = 0..<0
        reconfigureVisibleRows()
        if wasPinned {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor)
        }
        if !estimatedRows.isEmpty { setNeedsFlush() }
    }

    /// Measures up to `limit` estimated rows and corrects their heights, keeping the
    /// viewport anchored.
    private func refineEstimatedRows(limit: Int) {
        guard !estimatedRows.isEmpty else { return }
        var batch = IndexSet()
        for index in estimatedRows.prefix(limit) where index < rows.count { batch.insert(index) }
        estimatedRows.subtract(IndexSet(estimatedRows.prefix(limit)))
        measureWindow = 0..<rows.count
        let anchor = isPinnedToBottom ? nil : captureAnchor()
        isAdjustingScroll = true
        tableView.noteHeightOfRows(withIndexesChanged: batch)
        isAdjustingScroll = false
        measureWindow = 0..<0
        if isPinnedToBottom {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor)
        }
        if estimatedRows.isEmpty, !inLiveResize { engine.retainOnly(width: tableView.bounds.width) }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if estimatedRows.isEmpty { engine.retainOnly(width: tableView.bounds.width) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !needsFlush
        displayLink = link
    }

    // MARK: - Frame-coalesced updates

    /// Marks the transcript dirty. The next display frame applies the model's rows.
    func setNeedsFlush() {
        needsFlush = true
        if let displayLink {
            displayLink.isPaused = false
        } else if window == nil {
            // Offscreen: nothing to animate, apply on the next attach to a window.
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if needsFlush {
            needsFlush = false
            flush()
        }
        if !estimatedRows.isEmpty {
            // Refine offscreen estimates a batch per frame, smaller while the user drags.
            refineEstimatedRows(limit: inLiveResize ? 20 : 120)
        }
        if !needsFlush && estimatedRows.isEmpty { link.isPaused = true }
    }

    /// Applies the model's current rows now.
    func flush() {
        let start = CACurrentMediaTime()
        let newRows = model.rows
        let newPositions = AcpmuxRowGroupPosition.compute(newRows)
        let isInitial = rows.isEmpty
        let diff = AcpmuxTranscriptDiff(old: rows, new: newRows, oldPositions: positions, newPositions: newPositions)
        guard !diff.isEmpty else { return }
        let anchor = isPinnedToBottom ? nil : captureAnchor()
        let appendedAtEnd = !diff.inserted.isEmpty && diff.inserted.upperBound == newRows.count && diff.removed.count <= 1
        // The typing indicator turning into the first streamed bubble morphs in place.
        var typingPathToMorph: CGPath?
        if diff.removed.count == 1, diff.inserted.lowerBound == diff.removed.lowerBound,
           rows[diff.removed.lowerBound].content == .typing,
           newRows[diff.inserted.lowerBound].bubbleRole == .assistant {
            typingPathToMorph = layout(for: diff.removed.lowerBound).surfacePath
        }
        rows = newRows
        positions = newPositions
        // Row indexes shift with inserts and removals, so an unfinished refinement restarts
        // after this update with a fresh estimate pass.
        let restartEstimates = !estimatedRows.isEmpty
        estimatedRows = IndexSet()
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }

        if isInitial || diff.inserted.count > 200 || diff.removed.count > 200 {
            tableView.reloadData()
        } else {
            tableView.beginUpdates()
            if !diff.removed.isEmpty {
                // A dropped row (an abandoned partial message, a finished typing indicator)
                // fades and collapses instead of vanishing.
                let removedRealContent = !reduceMotion && diff.removed.count <= 3 && typingPathToMorph == nil
                tableView.removeRows(at: IndexSet(integersIn: diff.removed), withAnimation: removedRealContent ? [.effectFade, .slideUp] : [])
            }
            if !diff.inserted.isEmpty { tableView.insertRows(at: IndexSet(integersIn: diff.inserted), withAnimation: []) }
            tableView.endUpdates()
            if !diff.updated.isEmpty {
                // Growth applies in the same frame as the bottom pin below, so rows above
                // move once per frame with the content instead of lagging behind an animation.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    tableView.noteHeightOfRows(withIndexesChanged: diff.updated)
                }
                for index in diff.updated { reconfigure(row: index) }
            }
        }

        if restartEstimates {
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            measureWindow = max(0, visible.location - 20)..<min(rows.count, max(0, visible.location + visible.length + 20))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            measureWindow = 0..<0
        }
        if isPinnedToBottom {
            scrollToBottom(animated: !isInitial && !reduceMotion && appendedAtEnd)
        } else if let anchor {
            restore(anchor)
            if appendedAtEnd {
                unreadCount += newRows[diff.inserted].filter { $0.bubbleRole != nil }.count
            }
        }
        if appendedAtEnd, !isInitial, !reduceMotion {
            for index in diff.inserted {
                if index == diff.inserted.lowerBound, let typingPathToMorph,
                   let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? AcpmuxTranscriptRowCellView {
                    cell.animateFromTyping(typingPathToMorph, reduceMotion: reduceMotion)
                } else if !hiddenRowIDs.contains(rows[index].id) {
                    animateInsertion(row: index)
                }
            }
        }
        onScrollStateChanged?(isPinnedToBottom, unreadCount)
        onDidFlush?()
        recordFlush(duration: CACurrentMediaTime() - start)
    }

    private func recordFlush(duration: CFTimeInterval) {
        flushDurations.append(duration * 1000)
        if flushDurations.count > 240 { flushDurations.removeFirst(flushDurations.count - 240) }
    }

    // MARK: - Scroll state

    private struct Anchor {
        let rowID: String
        let offsetFromRowTop: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        guard range.length > 0, range.location < rows.count else { return nil }
        let row = range.location
        return Anchor(rowID: rows[row].id, offsetFromRowTop: visible.minY - tableView.rect(ofRow: row).minY)
    }

    private func restore(_ anchor: Anchor) {
        guard let index = rows.firstIndex(where: { $0.id == anchor.rowID }) else { return }
        let target = tableView.rect(ofRow: index).minY + anchor.offsetFromRowTop
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Pads the top so a short transcript sits at the bottom, next to the composer.
    private func updateBottomAnchoring() {
        let contentHeight = tableView.numberOfRows > 0 ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
        let top = max(6, scrollView.frame.height - contentHeight - scrollView.contentInsets.bottom)
        if abs(scrollView.contentInsets.top - top) > 0.5 {
            scrollView.contentInsets.top = top
        }
    }

    func scrollToBottom(animated: Bool) {
        tableView.layoutSubtreeIfNeeded()
        updateBottomAnchoring()
        let clip = scrollView.contentView
        let maxY = max(-scrollView.contentInsets.top, tableView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        let target = NSPoint(x: 0, y: maxY)
        isAdjustingScroll = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                self?.scrollView.reflectScrolledClipView(clip)
            }
        } else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
        isAdjustingScroll = false
        isPinnedToBottom = true
        unreadCount = 0
    }

    /// Jumps to the newest row and re-pins.
    func jumpToLatest() {
        scrollToBottom(animated: !reduceMotion)
        onScrollStateChanged?(true, 0)
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard !isAdjustingScroll else { return }
        let clip = scrollView.contentView.bounds
        let distanceFromBottom = tableView.frame.height - clip.maxY
        let pinned = distanceFromBottom < 28
        if pinned != isPinnedToBottom {
            isPinnedToBottom = pinned
            if pinned { unreadCount = 0 }
            onScrollStateChanged?(isPinnedToBottom, unreadCount)
        }
        if clip.minY < 400, model.canLoadOlder, !model.isLoadingOlder {
            Task { [weak self] in await self?.model.loadOlder() }
        }
    }

#if DEBUG
    /// Scrolls to the top (animated), as a user scroll would, for recordings.
    func debugScroll(toTop: Bool) {
        let clip = scrollView.contentView
        let target = NSPoint(x: 0, y: toTop ? -scrollView.contentInsets.top : max(0, tableView.frame.height - clip.bounds.height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(clip)
            self.clipViewBoundsChanged(Notification(name: NSView.boundsDidChangeNotification))
        }
    }

    /// Toggles the newest activity group, as a click on its header would.
    func debugToggleLastActivity() -> Bool {
        guard let row = rows.last(where: { if case .activity = $0.content { return true } else { return false } }) else { return false }
        toggle(row.id)
        return true
    }
#endif

    // MARK: - Morph support

    /// Hides a row's content while an overlay animates into its place.
    func setRowHidden(_ rowID: String, hidden: Bool) {
        if hidden { hiddenRowIDs.insert(rowID) } else { hiddenRowIDs.remove(rowID) }
        if let index = rows.firstIndex(where: { $0.id == rowID }) { reconfigure(row: index) }
    }

    /// The surface outline of `rowID` in its cell's coordinates.
    func surfacePath(of rowID: String) -> CGPath? {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        return layout(for: index).surfacePath
    }

    /// The bubble frame of `rowID` in this view's coordinates, if the row is laid out.
    func bubbleFrame(of rowID: String) -> CGRect? {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        let layout = layout(for: index)
        let rowRect = tableView.rect(ofRow: index)
        let inTable = layout.surfaceFrame.offsetBy(dx: rowRect.minX, dy: rowRect.minY)
        return convert(inTable, from: tableView)
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        if !measureWindow.isEmpty, !measureWindow.contains(row),
           let estimate = engine.height(
               for: rows[row],
               position: row < positions.count ? positions[row] : .standalone,
               width: tableView.bounds.width,
               expanded: expandedRowIDs.contains(rows[row].id)
           ) {
            if !estimate.exact { estimatedRows.insert(row) }
            return estimate.height
        }
        return layout(for: row).height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let layout = layout(for: row)
        if layout.surface == .typing {
            let cell = tableView.makeView(withIdentifier: AcpmuxTypingIndicatorCellView.identifier, owner: self)
                as? AcpmuxTypingIndicatorCellView ?? AcpmuxTypingIndicatorCellView(frame: .zero)
            cell.configure(layout: layout, theme: engine.theme, reduceMotion: reduceMotion)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: AcpmuxTranscriptRowCellView.identifier, owner: self)
            as? AcpmuxTranscriptRowCellView ?? AcpmuxTranscriptRowCellView(frame: .zero)
        cell.frame.size = CGSize(width: tableView.bounds.width, height: layout.height)
        cell.configure(rowID: rows[row].id, layout: layout, theme: engine.theme, hidden: hiddenRowIDs.contains(rows[row].id))
        cell.onToggle = { [weak self] rowID in self?.toggle(rowID) }
        cell.onRetry = { [weak self] rowID in self?.model.retryUndelivered(rowID: rowID) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func layout(for row: Int) -> AcpmuxRowLayout {
        engine.layout(
            for: rows[row],
            position: row < positions.count ? positions[row] : .standalone,
            width: tableView.bounds.width,
            expanded: expandedRowIDs.contains(rows[row].id)
        )
    }

    private func reconfigure(row: Int) {
        guard row < rows.count else { return }
        let layout = layout(for: row)
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AcpmuxTranscriptRowCellView {
            cell.frame.size.height = layout.height
            cell.configure(rowID: rows[row].id, layout: layout, theme: engine.theme, hidden: hiddenRowIDs.contains(rows[row].id))
        } else if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AcpmuxTypingIndicatorCellView {
            cell.configure(layout: layout, theme: engine.theme, reduceMotion: reduceMotion)
        }
    }

    private func reconfigureVisibleRows() {
        let range = tableView.rows(in: scrollView.contentView.bounds)
        guard range.length > 0 else { return }
        for row in range.location..<min(rows.count, range.location + range.length) { reconfigure(row: row) }
    }

    // MARK: - Interaction and animation

    private func toggle(_ rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        if expandedRowIDs.contains(rowID) { expandedRowIDs.remove(rowID) } else { expandedRowIDs.insert(rowID) }
        let wasPinned = isPinnedToBottom && index == rows.count - 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.25
            context.allowsImplicitAnimation = !reduceMotion
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        }
        reconfigure(row: index)
        if wasPinned { scrollToBottom(animated: !reduceMotion) }
    }

    private func animateInsertion(row: Int) {
        guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        let rowLayout = layout(for: row)
        guard let cell = view as? AcpmuxTranscriptRowCellView, let layer = cell.layer else {
            view.layer?.add(Self.fadeIn(), forKey: "acpmuxChat.insert.fade")
            return
        }
        // Anchor the scale at the tail: bottom-trailing for the user, bottom-leading for the agent.
        let frame = rowLayout.surfaceFrame
        let x = rowLayout.surface == .userBubble ? frame.maxX : frame.minX
        let flippedHost = layer.superlayer?.isGeometryFlipped ?? true
        let y = flippedHost ? frame.maxY : cell.bounds.height - frame.maxY
        if rowLayout.surface == .userBubble || rowLayout.surface == .assistantBubble {
            cell.animateArrival(anchor: CGPoint(x: x, y: y), reduceMotion: reduceMotion)
        } else {
            layer.add(Self.fadeIn(), forKey: "acpmuxChat.insert.fade")
        }
    }

    private static func fadeIn() -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        return fade
    }
}

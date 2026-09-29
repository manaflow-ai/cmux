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
            engine.retainOnly(width: width)
            let wasPinned = isPinnedToBottom
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            reconfigureVisibleRows()
            if wasPinned { scrollToBottom(animated: false) }
        }
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
        if !needsFlush { link.isPaused = true }
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
        rows = newRows
        positions = newPositions
        isAdjustingScroll = true
        defer { isAdjustingScroll = false }

        if isInitial || diff.inserted.count > 200 || diff.removed.count > 200 {
            tableView.reloadData()
        } else {
            tableView.beginUpdates()
            if !diff.removed.isEmpty { tableView.removeRows(at: IndexSet(integersIn: diff.removed), withAnimation: []) }
            if !diff.inserted.isEmpty { tableView.insertRows(at: IndexSet(integersIn: diff.inserted), withAnimation: []) }
            tableView.endUpdates()
            if !diff.updated.isEmpty {
                let animateGrowth = !reduceMotion && isPinnedToBottom && diff.inserted.isEmpty && diff.updated.count == 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = animateGrowth ? 0.12 : 0
                    context.allowsImplicitAnimation = animateGrowth
                    tableView.noteHeightOfRows(withIndexesChanged: diff.updated)
                }
                for index in diff.updated { reconfigure(row: index) }
            }
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
            for index in diff.inserted { animateInsertion(row: index) }
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

    // MARK: - Morph support

    /// Hides a row's content while an overlay animates into its place.
    func setRowHidden(_ rowID: String, hidden: Bool) {
        if hidden { hiddenRowIDs.insert(rowID) } else { hiddenRowIDs.remove(rowID) }
        if let index = rows.firstIndex(where: { $0.id == rowID }) { reconfigure(row: index) }
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
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false), let layer = cell.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = 14
        spring.toValue = 0
        spring.damping = 16
        spring.stiffness = 220
        spring.mass = 1
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        layer.add(spring, forKey: "acpmuxChat.insert.translate")
        layer.add(fade, forKey: "acpmuxChat.insert.fade")
    }
}

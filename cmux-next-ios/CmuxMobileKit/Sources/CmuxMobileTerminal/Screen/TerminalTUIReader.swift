#if os(iOS)
import CmuxMobileDesign
import UIKit

/// A plain scroll over a full-screen app's history (Leo, 2026-11-24: "we can
/// just treat the scroll like any pedestrian scroll" and "where's us simply
/// scrolling a cached-on-phone view of a lot of the existing terminal data
/// that's been sent and rendered? ... if it won't change, there's no lag
/// that should happen in those cases").
///
/// The app (Claude Code, vim) owns its screen and draws only that: its
/// history above is gone from the grid. The phone's projection keeps every
/// row the app scrolled away (`cmux-terminal-projection`'s transcript), so a
/// drag toward older content opens this reader over the app's area: a
/// UIScrollView whose content is the whole transcript, the app's current
/// screen at its bottom. It moves by points, decelerates, bounces and
/// scrolls to the top like any iOS scroll view, with no wheel round trip to
/// the app: every row it shows is already on the phone.
///
/// A Ghostty surface draws the rows: one surface of a few screens fed the
/// transcript once, placed at a row boundary in the content. As the reader
/// nears its edge it asks Ghostty for another viewport (one request in
/// flight) and moves the surface only in the transaction that presents that
/// viewport's frame, as the shell's page does.
///
/// It opens at the bottom, looking exactly like the live screen, and closes
/// when a scroll settles back at the bottom: the app's own screen shows again.
///
/// Text selects in it as on the shell's page ("we can still highlight text
/// and whatnot"): a long press selects a word, the handles move either end
/// (scrolling the reader at its edges), Copy reads the rows from the reader's
/// own surface, and a tap ends it. The rows are the document's, so the
/// highlight scrolls with them; while one shows, the reader stays open.
@MainActor
final class TerminalTUIReader: NSObject, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let surface = TerminalSurfaceView(frame: .zero)
    private let content = UIView()
    /// Text selection over the document's rows (row 0: the oldest kept row).
    let selection = TerminalSelectionController()

    /// The reader is shown (between `open` and `close`).
    private(set) var isOpen = false
    /// The reader closed (it settled at the bottom, or the app's area changed).
    var onClose: () -> Void = {}

    private var cellHeight: CGFloat = 0
    private var documentRows = 0
    private var surfaceRows = 0
    /// The viewport Ghostty was asked for, and the one it last reported.
    private var requestedTop = -1
    private var reportedTop = -1
    /// The viewport whose frame is on screen (the surface sits at it).
    private var placedTop = -1
    /// The finger's drag of the app's pan (before the reader's own pan owns
    /// the touches): the offset where it began.
    private var dragStartOffset: CGFloat = 0
    private var fling: CADisplayLink?
    private var flingVelocity: CGFloat = 0
    private var flingLast: CFTimeInterval = 0

    /// DEBUG frame pacing of the reader's scroll: display frames seen while it
    /// moved, frames later than 1.5 display intervals, the longest interval.
    static var pacing = (frames: 0, hitches: 0, longestMs: 0.0)
    private var pacingLink: CADisplayLink?
    private var pacingPrevious: CFTimeInterval = 0
    private var pacingIdleFrames = 0

    override init() {
        super.init()
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .normal
        scrollView.accessibilityIdentifier = "terminal.tuiReader"
        scrollView.addSubview(content)
        content.addSubview(surface)
        surface.isUserInteractionEnabled = false
        surface.onEvent = { [weak self] event in
            guard case .scrollbar(_, let offset, _) = event else { return }
            self?.reportedTop = offset
        }
        surface.onPresent = { [weak self] in self?.presented() }
        installSelection()
    }

    // MARK: Selection

    /// The cell's size and where cell (0, 0) of document row 0 sits in the content.
    private var cellWidth: CGFloat { surface.cellSize.width }
    private var gridOrigin: CGPoint {
        let padding = surface.gridPadding
        return CGPoint(x: surface.frame.minX + padding.x, y: padding.y)
    }

    /// The document rows the surface holds now (its placed viewport).
    private var heldRows: ClosedRange<Int>? {
        guard placedTop >= 0, surfaceRows > 0 else { return nil }
        return placedTop...min(documentRows, placedTop + surfaceRows) - 1
    }

    private func installSelection() {
        selection.isEnabled = { [weak self] in
            guard let self else { return false }
            return isOpen && placedTop >= 0 && cellHeight > 0 && cellWidth > 0
        }
        selection.columns = { [weak self] in max(1, self?.surface.grid.columns ?? 1) }
        selection.documentRows = { [weak self] in 0..<(self?.documentRows ?? 0) }
        selection.cellAt = { [weak self] point in
            guard let self, cellHeight > 0, cellWidth > 0, let held = heldRows else { return nil }
            let origin = gridOrigin
            // A handle stops at the edge of the rows the surface holds.
            let row = min(max(held.lowerBound, Int(floor((point.y - origin.y) / cellHeight))), held.upperBound)
            let column = Int(floor((point.x - origin.x) / cellWidth))
            return TerminalCellPoint(row: row, column: min(max(0, column), max(0, surface.grid.columns - 1)))
        }
        selection.rectFor = { [weak self] point in
            guard let self else { return .zero }
            let origin = gridOrigin
            return CGRect(x: origin.x + CGFloat(point.column) * cellWidth, y: origin.y + CGFloat(point.row) * cellHeight,
                          width: cellWidth, height: cellHeight)
        }
        selection.rowText = { [weak self] row in
            guard let self, let held = heldRows, held.contains(row) else { return nil }
            let last = max(0, surface.grid.columns - 1)
            return surface.viewportText(from: TerminalCellPoint(row: row - held.lowerBound, column: 0),
                                        to: TerminalCellPoint(row: row - held.lowerBound, column: last))
        }
        selection.text = { [weak self] start, end in
            guard let self, let held = heldRows else { return nil }
            // Rows the surface does not hold now (the edge autoscroll carried
            // the selection past them): the whole document, read once.
            guard held.contains(start.row), held.contains(end.row) else {
                return surface.screenRows()?.text(from: start, to: end)
            }
            return surface.viewportText(from: TerminalCellPoint(row: start.row - held.lowerBound, column: start.column),
                                        to: TerminalCellPoint(row: end.row - held.lowerBound, column: end.column))
        }
        selection.visibleBand = { [weak self] in 0...max(0, self?.scrollView.bounds.height ?? 0) }
        selection.offsetRange = { [weak self] in 0...max(0, self?.maxOffset ?? 0) }
        selection.autoscrollBegan = { [weak self] in self?.stopFling() }
        selection.install(in: scrollView)
    }

    /// A tap on the reader: it ends a selection (true), as on the shell's page.
    func tapped() -> Bool {
        guard selection.selection != nil else { return false }
        selection.clear()
        return true
    }

    /// Opens over `frame` (in `host`): the transcript's rows at `cellHeight`
    /// each, `width` wide at `surfaceX` (the app's surface's: the same
    /// columns, where they are), at
    /// the bottom. `themeMacID`: the app's surface's Mac, for its colors.
    func open(_ transcript: TerminalTUITranscript, in host: UIView, frame: CGRect, surfaceX: CGFloat, width: CGFloat,
              cellHeight: CGFloat, themeMacID: String?, background: UIColor?) {
        guard !isOpen, cellHeight > 0, transcript.rows > 0 else { return }
        isOpen = true
        self.cellHeight = cellHeight
        documentRows = transcript.rows
        let visibleRows = Int(ceil(frame.height / cellHeight))
        // Two screens: a screen of margin split above and below the visible rows.
        surfaceRows = min(transcript.rows, max(visibleRows, 2 * visibleRows))
        requestedTop = -1
        reportedTop = -1
        placedTop = -1
        scrollView.frame = frame
        scrollView.backgroundColor = background
        content.frame = CGRect(x: 0, y: 0, width: frame.width, height: CGFloat(documentRows) * cellHeight)
        scrollView.contentSize = content.frame.size
        surface.themeMacID = themeMacID
        surface.frame = CGRect(x: surfaceX, y: 0, width: width, height: CGFloat(surfaceRows) * cellHeight)
        // Hidden until the frame of the rows it opens on is placed: the app's
        // own screen shows under it meanwhile, so nothing blinks.
        scrollView.alpha = 0
        host.addSubview(scrollView)
        scrollView.contentOffset.y = maxOffset
        var bytes = Data("\u{1b}c".utf8)
        bytes.append(transcript.bytes)
        surface.feed(bytes, completion: { [weak self] in self?.updateViewport() })
    }

    /// Leaves the reader: the app's screen shows again.
    func close() {
        guard isOpen else { return }
        isOpen = false
        selection.clear()
        stopFling()
        stopPacing()
        scrollView.removeFromSuperview()
        onClose()
    }

    private var maxOffset: CGFloat { max(0, scrollView.contentSize.height - scrollView.bounds.height) }

    // MARK: The app's pan, handed over

    /// The app's drag that opened the reader began (its translation from here).
    func dragBegan() {
        stopFling()
        dragStartOffset = scrollView.contentOffset.y
    }

    /// The app's drag moved: `translationY` since it began (positive: the
    /// finger moved down, toward older rows). Past the top it rubber-bands.
    func dragMoved(translationY: CGFloat) {
        var y = dragStartOffset - translationY
        if y < 0 { y = -Self.rubberBand(-y, dimension: scrollView.bounds.height) }
        y = min(y, maxOffset)
        scrollView.contentOffset.y = y
    }

    /// The app's drag ended at `velocityY` (points per second, finger
    /// direction): the reader decelerates at UIScrollView's normal rate.
    func dragEnded(velocityY: CGFloat) {
        flingVelocity = -velocityY
        flingLast = 0
        let link = CADisplayLink(target: self, selector: #selector(stepFling(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        fling = link
    }

    @objc private func stepFling(_ link: CADisplayLink) {
        if flingLast == 0 { flingLast = link.timestamp; return }
        let dt = link.targetTimestamp - flingLast
        flingLast = link.targetTimestamp
        var y = scrollView.contentOffset.y
        if y < 0 {
            // Back from the top's rubber band, like a released scroll view.
            y += (0 - y) * min(1, CGFloat(dt) * 12)
            if abs(y) < 0.5 { y = 0 }
            flingVelocity = 0
        } else {
            flingVelocity *= CGFloat(pow(Double(UIScrollView.DecelerationRate.normal.rawValue), dt * 1000))
            y += flingVelocity * CGFloat(dt)
            if y < 0 || y > maxOffset { flingVelocity = 0 }
            y = min(max(y, 0), maxOffset)
        }
        scrollView.contentOffset.y = y
        if abs(flingVelocity) < 8, y >= 0 {
            stopFling()
            settled()
        }
    }

    private func stopFling() {
        fling?.invalidate()
        fling = nil
    }

    /// UIScrollView's rubber band: `offset` past the edge shows as less.
    /// The math lives in CmuxMobileDesignCore (`TerminalScrollMath`), tested on Linux.
    static func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        TerminalScrollMath.rubberBand(offset, dimension: dimension)
    }

    /// DEBUG demo: a fling of the reader at `velocity` (points per second,
    /// positive toward older rows), through the same path as a finger's release.
    func demoFling(velocity: CGFloat) {
        dragBegan()
        dragEnded(velocityY: velocity)
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        startPacing()
        updateViewport()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { stopFling() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled() }

    /// A scroll ended: at the bottom the app's own screen shows again.
    private func settled() {
        guard isOpen, !scrollView.isTracking, selection.selection == nil,
              scrollView.contentOffset.y >= maxOffset - 1 else { return }
        close()
    }

    /// Asks Ghostty for a viewport with margin around the visible rows once
    /// they come within half a margin of the placed viewport's edges.
    private func updateViewport() {
        guard isOpen, cellHeight > 0, surfaceRows > 0, requestedTop == reportedTop || requestedTop < 0 else { return }
        let offset = min(max(0, scrollView.contentOffset.y), maxOffset)
        let visibleTop = Int(floor(offset / cellHeight))
        let visibleBottom = Int(ceil((offset + scrollView.bounds.height) / cellHeight))
        let margin = max(0, surfaceRows - (visibleBottom - visibleTop)) / 2
        let maxTop = max(0, documentRows - surfaceRows)
        let current = placedTop
        let needs = current < 0
            || (visibleTop < current + margin / 2 && current > 0)
            || (visibleBottom > current + surfaceRows - margin / 2 && current < maxTop)
        guard needs else { return }
        let top = min(max(0, visibleTop - margin), maxTop)
        guard top != current else { return }
        requestedTop = top
        surface.scroll(toRow: top)
    }

    /// A frame was presented: the surface moves to its viewport in this
    /// transaction once it is the one asked for.
    private func presented() {
        guard isOpen, requestedTop >= 0, reportedTop == requestedTop else { return }
        if placedTop != reportedTop {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame.origin.y = CGFloat(reportedTop) * cellHeight
            CATransaction.commit()
            placedTop = reportedTop
            selection.redraw()
        }
        if scrollView.alpha == 0 { scrollView.alpha = 1 }
        updateViewport()
    }

    /// The rows on screen now, oldest first, as Ghostty drew them (nil until
    /// a frame is placed). For tests and the demo's probe.
    func visibleRowTexts() -> [String]? {
        guard isOpen, placedTop >= 0, cellHeight > 0 else { return nil }
        let first = Int(floor(max(0, scrollView.contentOffset.y) / cellHeight)) - placedTop
        let last = Int(ceil((max(0, scrollView.contentOffset.y) + scrollView.bounds.height) / cellHeight)) - placedTop - 1
        guard first >= 0, last < surfaceRows, first <= last else { return nil }
        let end = max(0, surface.grid.columns - 1)
        return (first...last).map {
            surface.viewportText(from: TerminalCellPoint(row: $0, column: 0), to: TerminalCellPoint(row: $0, column: end)) ?? ""
        }
    }

    /// The reader shows a placed frame (it opened and drew).
    var isShowing: Bool { isOpen && scrollView.alpha > 0 }

    // MARK: Frame pacing

    private func startPacing() {
        guard pacingLink == nil else { pacingIdleFrames = 0; return }
        pacingPrevious = 0
        pacingIdleFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(pace(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        pacingLink = link
    }

    @objc private func pace(_ link: CADisplayLink) {
        if pacingPrevious > 0 {
            let interval = link.timestamp - pacingPrevious
            let expected = link.targetTimestamp - link.timestamp
            Self.pacing.frames += 1
            Self.pacing.longestMs = max(Self.pacing.longestMs, interval * 1000)
            if expected > 0, interval > expected * 1.5 { Self.pacing.hitches += 1 }
        }
        pacingPrevious = link.timestamp
        // Still for a few frames: the scroll stopped.
        pacingIdleFrames += 1
        if pacingIdleFrames > 6 { stopPacing() }
    }

    private func stopPacing() {
        pacingLink?.invalidate()
        pacingLink = nil
    }
}
#endif

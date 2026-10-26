#if os(iOS)
import UIKit

/// Text selection over the terminal's rows, scrollback included (G-14,
/// T-SEL-01/02), with iOS conventions: a long press selects the word under the
/// finger (moving the finger then extends it), two handles move either end,
/// and the edit menu offers Copy and Select All. A tap clears it. The
/// highlight lives in the scroll view's content, so it scrolls with the rows.
/// The screen supplies the geometry; Ghostty supplies the text.
@MainActor
final class TerminalSelectionController: NSObject, @MainActor UIEditMenuInteractionDelegate, @MainActor UIGestureRecognizerDelegate {
    /// The cell under a point in the scroll view's content (nil off the document).
    var cellAt: (CGPoint) -> TerminalCellPoint? = { _ in nil }
    /// A cell's rect in the scroll view's content.
    var rectFor: (TerminalCellPoint) -> CGRect = { _ in .zero }
    var rowText: (Int) -> String? = { _ in nil }
    var text: (TerminalCellPoint, TerminalCellPoint) -> String? = { _, _ in nil }
    var columns: () -> Int = { 80 }
    /// The document's first row and one past its last.
    var documentRows: () -> Range<Int> = { 0..<0 }
    /// Selection is off (a TUI on the alternate screen draws its own).
    var isEnabled: () -> Bool = { true }
    /// The visible rows, in the scroll view's frame (between the top bar and
    /// the composer), and the offsets the page may scroll to: a finger near
    /// either edge scrolls the page so the selection reaches rows off screen.
    var visibleBand: () -> ClosedRange<CGFloat> = { 0...0 }
    var offsetRange: () -> ClosedRange<CGFloat> = { 0...0 }
    /// The page is about to scroll for the selection, and has stopped.
    var autoscrollBegan: () -> Void = {}
    var autoscrollEnded: () -> Void = {}

    private(set) var selection: TerminalTextSelection? {
        didSet { if selection != oldValue { redraw() } }
    }

    /// The view the selection lives in: the scroll view (shell), or the TUI
    /// host (alternate screen: no scrollback, so no edge autoscroll).
    private weak var host: UIView?
    private var scrollView: UIScrollView? { host as? UIScrollView }
    private let highlight = SelectionHighlightView()
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)
    private var menu: UIEditMenuInteraction?
    private(set) var longPress: UILongPressGestureRecognizer?
    private var dragging: TerminalTextSelection.Handle?
    /// Edge autoscroll (G-14): the finger in the scroll view's frame, the
    /// part being moved (a handle, or the long press's head), the display link.
    private let autoscroll = TerminalSelectionAutoscroll()
    private var autoscrollFinger: CGPoint?
    private var autoscrollMovesHead = false
    private var autoscrollLink: CADisplayLink?
    private var autoscrollLastTime: CFTimeInterval = 0

    func install(in host: UIView) {
        self.host = host
        highlight.isUserInteractionEnabled = false
        highlight.isHidden = true
        host.addSubview(highlight)
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanned(_:)))
            handle.addGestureRecognizer(pan)
            // A drag that starts on a handle moves the handle, not the page.
            (host as? UIScrollView)?.panGestureRecognizer.require(toFail: pan)
            host.addSubview(handle)
        }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = self
        host.addGestureRecognizer(press)
        longPress = press
        let menu = UIEditMenuInteraction(delegate: self)
        host.addInteraction(menu)
        self.menu = menu
    }

    /// The overlay stays above the surface as the screen re-adds views.
    func bringToFront() {
        guard let host else { return }
        for view in [highlight, startHandle, endHandle] { host.bringSubviewToFront(view) }
    }

    func clear() {
        stopAutoscroll()
        guard selection != nil else { return }
        selection = nil
        menu?.dismissMenu()
    }

    /// The rows moved in the document (a prune renumbers them): keep the selection on its text.
    func shiftRows(by delta: Int) {
        guard var current = selection, delta != 0 else { return }
        // The selected rows left the history: nothing to keep.
        guard current.start.row + delta >= 0 else { return clear() }
        current.anchor.row += delta
        current.head.row += delta
        selection = current
    }

    /// Re-lays the highlight (the document or the cell size changed).
    func redraw() {
        guard let selection, isEnabled() else {
            highlight.isHidden = true
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let spans = selection.rowSpans(columns: columns())
        highlight.rects = spans.map { span in
            let first = rectFor(TerminalCellPoint(row: span.row, column: span.columns.lowerBound))
            let last = rectFor(TerminalCellPoint(row: span.row, column: span.columns.upperBound - 1))
            return first.union(last)
        }
        let bounds = highlight.rects.reduce(CGRect.null) { $0.union($1) }
        highlight.frame = bounds.isNull ? .zero : bounds.insetBy(dx: -1, dy: -1)
        highlight.setNeedsDisplay()
        highlight.isHidden = bounds.isNull
        bringToFront()
        let start = rectFor(selection.start), end = rectFor(selection.end)
        startHandle.place(caretTop: CGPoint(x: start.minX, y: start.minY), height: start.height)
        endHandle.place(caretTop: CGPoint(x: end.maxX, y: end.minY), height: end.height)
        startHandle.isHidden = false
        endHandle.isHidden = false
    }

    // MARK: Gestures

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard let host, isEnabled() else { return }
        let point = press.location(in: host)
        switch press.state {
        case .began:
            guard let cell = cellAt(point) else { return }
            selection = TerminalTextSelection.word(at: cell, line: rowText(cell.row) ?? "", columns: columns())
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            // Moving after the press extends the selection, like a drag-select.
            guard var current = selection, let cell = cellAt(point) else { return }
            current.head = cell
            selection = current
            trackAutoscroll(finger: point, movesHead: true)
        case .ended:
            stopAutoscroll()
            showMenu()
        case .cancelled, .failed:
            stopAutoscroll()
        default:
            break
        }
    }

    @objc private func handlePanned(_ pan: UIPanGestureRecognizer) {
        guard let host, var current = selection else { return }
        if pan.state == .began {
            menu?.dismissMenu()
            dragging = pan.view === startHandle ? .start : .end
        }
        // Every report moves the handle, the first and last included (a
        // quick drag can arrive as a begin and an end only).
        if [.began, .changed, .ended].contains(pan.state), let handle = dragging {
            // The finger sits on the handle's knob: aim at the row beside it.
            var point = pan.location(in: host)
            point.y += handle == .start ? 10 : -10
            if let cell = cellAt(point) {
                current.move(handle, to: cell)
                dragging = current.headHandle
                selection = current
            }
            if pan.state != .ended { trackAutoscroll(finger: point, movesHead: false) }
        }
        if [.ended, .cancelled, .failed].contains(pan.state) {
            stopAutoscroll()
            dragging = nil
            showMenu()
        }
    }

    // MARK: Edge autoscroll

    /// The finger moved to `contentPoint` (scroll view content): near the top
    /// or bottom of the visible rows the page scrolls, every display frame,
    /// and the moving end follows the cell under the still finger.
    private func trackAutoscroll(finger contentPoint: CGPoint, movesHead: Bool) {
        guard let scrollView else { return }
        let framePoint = CGPoint(x: contentPoint.x, y: contentPoint.y - scrollView.contentOffset.y)
        autoscrollFinger = framePoint
        autoscrollMovesHead = movesHead
        let band = visibleBand()
        let velocity = autoscroll.velocity(fingerY: framePoint.y, visibleTop: band.lowerBound, visibleBottom: band.upperBound)
        if velocity == 0 {
            stopAutoscroll()
            return
        }
        guard autoscrollLink == nil else { return }
        autoscrollBegan()
        let link = CADisplayLink(target: self, selector: #selector(autoscrollTick(_:)))
        link.preferredFrameRateRange = .terminal
        link.add(to: .main, forMode: .common)
        autoscrollLink = link
        autoscrollLastTime = 0
    }

    private func stopAutoscroll() {
        autoscrollFinger = nil
        guard let link = autoscrollLink else { return }
        link.invalidate()
        autoscrollLink = nil
        autoscrollEnded()
    }

    @objc private func autoscrollTick(_ link: CADisplayLink) {
        guard let scrollView, let finger = autoscrollFinger, var current = selection else { return stopAutoscroll() }
        let dt = autoscrollLastTime == 0 ? link.duration : link.timestamp - autoscrollLastTime
        autoscrollLastTime = link.timestamp
        let band = visibleBand()
        let velocity = autoscroll.velocity(fingerY: finger.y, visibleTop: band.lowerBound, visibleBottom: band.upperBound)
        let y = autoscroll.step(offset: scrollView.contentOffset.y, velocity: velocity, dt: min(dt, 0.05), range: offsetRange())
        guard velocity != 0, abs(y - scrollView.contentOffset.y) > 0.01 else { return }
        scrollView.contentOffset.y = y
        // The finger stays still while the rows move under it.
        var point = CGPoint(x: finger.x, y: finger.y + y)
        if !autoscrollMovesHead, let handle = dragging { point.y += handle == .start ? 10 : -10 }
        guard let cell = cellAt(point) else { return }
        if autoscrollMovesHead {
            current.head = cell
        } else if let handle = dragging {
            current.move(handle, to: cell)
            dragging = current.headHandle
        }
        selection = current
    }

    /// A long press is selecting or extending under the finger.
    var isPressing: Bool {
        guard let longPress else { return false }
        return longPress.state == .began || longPress.state == .changed
    }

    /// The touch is on a visible selection handle (the handle moves, not the page or the app).
    func ownsTouch(_ touch: UITouch) -> Bool {
        guard let view = touch.view else { return false }
        return [startHandle, endHandle].contains { !$0.isHidden && view.isDescendant(of: $0) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled()
    }

    // MARK: Edit menu

    private func showMenu() {
        guard let selection, let menu else { return }
        let start = rectFor(selection.start)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: start.midX, y: start.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selection != nil else { return nil }
        let copy = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy() }
        let all = UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.selectAll()
        }
        return UIMenu(children: [copy, all])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        highlight.isHidden ? .null : highlight.frame
    }

    func copy() {
        guard let selection, let raw = text(selection.start, selection.end) else { return }
        UIPasteboard.general.string = TerminalTextSelection.cleaned(raw)
        clear()
    }

    func selectAll() {
        let rows = documentRows()
        guard !rows.isEmpty else { return }
        selection = TerminalTextSelection.all(originRow: rows.lowerBound, endRow: rows.upperBound, columns: columns())
        showMenu()
    }
}

private extension UIColor {
    /// iOS text selection's blue. Not the view's tint: the app tints with its
    /// label colour, which drew the highlight as a dim grey and the handles
    /// black on the terminal's black (VERIFY-round8 T-SEL).
    static var terminalSelection: UIColor { .systemBlue }
}

/// The selection's tint, one rect per row.
private final class SelectionHighlightView: UIView {
    var rects: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        UIColor.terminalSelection.withAlphaComponent(0.4).setFill()
        for row in rects {
            UIBezierPath(rect: row.offsetBy(dx: -frame.minX, dy: -frame.minY)).fill()
        }
    }
}

/// An iOS selection handle: a caret with a knob above (start) or below (end),
/// with a 44 pt touch area.
private final class SelectionHandleView: UIView {
    let isStart: Bool
    private let caret = UIView()
    private let knob = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        caret.backgroundColor = .terminalSelection
        knob.backgroundColor = .terminalSelection
        knob.layer.cornerRadius = 5
        addSubview(caret)
        addSubview(knob)
        isAccessibilityElement = true
        accessibilityLabel = isStart ? String(localized: "Selection start") : String(localized: "Selection end")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func place(caretTop: CGPoint, height: CGFloat) {
        let width: CGFloat = 44
        frame = CGRect(x: caretTop.x - width / 2, y: caretTop.y - 22, width: width, height: height + 44)
        caret.frame = CGRect(x: width / 2 - 1, y: 22, width: 2, height: height)
        knob.frame = CGRect(x: width / 2 - 5, y: isStart ? 12 : 22 + height, width: 10, height: 10)
    }
}
#endif

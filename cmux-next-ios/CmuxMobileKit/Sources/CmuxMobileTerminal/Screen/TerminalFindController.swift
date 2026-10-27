#if os(iOS)
import OSLog
import UIKit

private let findLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal-find")

/// Find in the terminal (the Mac's Find…, Find Next, Find Previous and Hide Find Bar):
/// the system find bar (`UIFindInteraction`, Apple HIG "Searching") over the phone's
/// own copy of the terminal, its scrollback included. Every match is highlighted in
/// the rows; the selected one is brighter, and the page scrolls to it. The bar's
/// arrows and Return step through the matches, the count reads "2 of 5", and Done
/// (or Escape) ends the search and removes the highlights.
///
/// The screen supplies the rows and their geometry (as for ``TerminalSelectionController``):
/// the whole screen on the shell, the visible screen of a full-screen app.
@MainActor
final class TerminalFindController: NSObject, @MainActor UIFindInteractionDelegate {
    /// The rows to search: `rows[i]` is row `firstRow + i`, `wraps[i]` says it goes on
    /// (soft wrapped) on the next row. Nil when nothing can be read now.
    var readRows: () -> (rows: [String], wraps: [Bool], firstRow: Int, columns: Int)? = { nil }
    /// A cell's rect in the highlight host's coordinates.
    var rectFor: (TerminalCellPoint) -> CGRect = { _ in .zero }
    /// The rows the page draws now (only their matches are highlighted).
    var drawnRows: () -> Range<Int> = { 0..<0 }
    /// The view the highlights live in (the scroll view's content, or a full-screen app's host).
    var highlightHost: () -> UIView? = { nil }
    /// Brings `match` into view.
    var reveal: (TerminalFindResults.Match) -> Void = { _ in }
    /// The bar closed: give the keyboard back to the terminal when it had it.
    var ended: (_ restoreFocus: Bool) -> Void = { _ in }

    private(set) var results = TerminalFindResults()
    private var interaction: UIFindInteraction?
    private let highlight = TerminalFindHighlightView()
    private var restoreFocus = false

    /// The find bar is up.
    var isActive: Bool { interaction?.isFindNavigatorVisible == true }

    func install(in view: UIView) {
        let interaction = UIFindInteraction(sessionDelegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction
        highlight.isUserInteractionEnabled = false
        highlight.isHidden = true
    }

    /// Find… (the page menu, Cmd-F): shows the bar with the last query.
    func present(terminalHadFocus: Bool) {
        guard let interaction else { return }
        if !interaction.isFindNavigatorVisible { restoreFocus = terminalHadFocus }
        interaction.presentFindNavigator(showingReplace: false)
    }

    /// Find Next / Find Previous (Cmd-G, Shift-Cmd-G): opens the bar first when it is closed.
    func step(forward: Bool, terminalHadFocus: Bool) {
        guard let interaction else { return }
        guard interaction.isFindNavigatorVisible else { return present(terminalHadFocus: terminalHadFocus) }
        if forward { interaction.findNext() } else { interaction.findPrevious() }
    }

    /// Hide Find Bar (Escape in the bar does the same).
    func dismiss() {
        interaction?.dismissFindNavigator()
    }

    // MARK: Searching

    fileprivate func search(_ query: String, revealing: Bool = true) {
        guard let source = readRows() else {
            results = TerminalFindResults()
            redraw()
            return
        }
        results = TerminalFindResults(rows: source.rows, wraps: source.wraps, firstRow: source.firstRow,
                                      columns: source.columns, query: query)
        findLog.notice("find: \(self.results.matches.count, privacy: .public) matches in \(source.rows.count, privacy: .public) rows")
        if revealing, let match = results.selectedMatch { reveal(match) }
        redraw()
    }

    fileprivate func highlightNext(forward: Bool) {
        results.step(forward: forward)
        if let match = results.selectedMatch { reveal(match) }
        redraw()
    }

    fileprivate func invalidate() {
        results = TerminalFindResults()
        redraw()
    }

    /// The rows under the find changed wholesale (a full-screen app started or ended,
    /// the mirror was reset and replayed): search the new rows, near the same place.
    func rowsReplaced() {
        guard isActive, !results.query.isEmpty else { return }
        let row = results.selectedMatch?.row
        search(results.query, revealing: false)
        if let row {
            results.select(nearestRow: row)
            redraw()
        }
        interaction?.updateResultCount()
    }

    /// Ghostty dropped its oldest rows: the matches keep their text.
    func shiftRows(by delta: Int) {
        guard !results.matches.isEmpty else { return }
        results.shiftRows(by: delta)
        interaction?.updateResultCount()
        redraw()
    }

    /// Lays the highlights over the drawn rows again (the page moved, the document changed).
    func redraw() {
        guard !results.matches.isEmpty, let host = highlightHost() else {
            highlight.isHidden = true
            return
        }
        if highlight.superview !== host { host.addSubview(highlight) }
        let selected = results.selected
        var rects: [(CGRect, Bool)] = []
        for (index, match) in results.matches(in: drawnRows()) {
            for segment in match.segments {
                let first = rectFor(TerminalCellPoint(row: segment.row, column: segment.start))
                let last = rectFor(TerminalCellPoint(row: segment.row, column: segment.end))
                rects.append((first.union(last), index == selected))
            }
        }
        let bounds = rects.reduce(CGRect.null) { $0.union($1.0) }
        guard !bounds.isNull else {
            highlight.isHidden = true
            return
        }
        highlight.frame = bounds.insetBy(dx: -2, dy: -2)
        highlight.rects = rects.map { ($0.0.offsetBy(dx: -highlight.frame.minX, dy: -highlight.frame.minY), $0.1) }
        highlight.isHidden = false
        highlight.setNeedsDisplay()
        host.bringSubviewToFront(highlight)
    }

    // MARK: UIFindInteractionDelegate

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        TerminalFindSession(owner: self)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        invalidate()
        let restore = restoreFocus
        restoreFocus = false
        ended(restore)
    }
}

/// The find bar's session: the bar asks it to search and step, and reads its count.
@MainActor
private final class TerminalFindSession: UIFindSession {
    private weak var owner: TerminalFindController?

    init(owner: TerminalFindController) {
        self.owner = owner
        super.init()
    }

    override var resultCount: Int { owner?.results.matches.count ?? 0 }

    override var highlightedResultIndex: Int { owner?.results.selected ?? NSNotFound }

    override var supportsReplacement: Bool { false }

    override func performSearch(query: String, options: UITextSearchOptions?) {
        owner?.search(query)
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        owner?.highlightNext(forward: direction == .forward)
    }

    override func invalidateFoundResults() {
        owner?.invalidate()
    }
}

/// Every match's cells tinted; the selected match brighter, with an outline.
private final class TerminalFindHighlightView: UIView {
    var rects: [(CGRect, Bool)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        for (cells, selected) in rects {
            let path = UIBezierPath(roundedRect: cells, cornerRadius: 2)
            (selected ? UIColor.systemYellow.withAlphaComponent(0.55) : UIColor.systemYellow.withAlphaComponent(0.25)).setFill()
            path.fill()
            if selected {
                UIColor.systemYellow.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}
#endif

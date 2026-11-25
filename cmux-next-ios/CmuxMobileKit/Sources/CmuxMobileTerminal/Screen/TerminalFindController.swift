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
    /// The daemon's find for this terminal (`terminal-find`), nil when the page searches its own
    /// rows: a full-screen app, a projection, a session without a Mac, a daemon without the command.
    var daemon: () -> TerminalFindDaemonSource? = { nil }
    /// Brings `match` into view.
    var reveal: (TerminalFindResults.Match) -> Void = { _ in }
    /// The bar closed: give the keyboard back to the terminal when it had it.
    var ended: (_ restoreFocus: Bool) -> Void = { _ in }

    private(set) var results = TerminalFindResults()
    private var interaction: UIFindInteraction?
    private let highlight = TerminalFindHighlightView()
    private var restoreFocus = false
    /// The bar's toggles: Match Case and Full Words are the system bar's own options; Regular
    /// Expression is added to its options menu.
    private var options = TerminalFindOptions()
    /// The daemon's pages are streaming in.
    private var streamTask: Task<Void, Never>?
    /// A selected match older than the mirror: reveal it when its history arrives.
    private var revealWhenLoaded = false

    /// The find bar is up.
    var isActive: Bool { interaction?.isFindNavigatorVisible == true }

    func install(in view: UIView) {
        let interaction = UIFindInteraction(sessionDelegate: self)
        interaction.optionsMenuProvider = { [weak self] elements in
            guard let self else { return UIMenu(children: elements) }
            let regex = UIAction(title: String(localized: "Regular Expression"),
                                 state: self.options.regex ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.options.regex.toggle()
                self.restartSearch()
            }
            return UIMenu(children: elements + [UIMenu(options: .displayInline, children: [regex])])
        }
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

    /// The rows as last read: one whole-screen read when the bar opens (and again after
    /// new output, the next time the query changes or the rows are replaced), never one
    /// per keystroke. Ghostty's reads take the terminal's lock.
    private var snapshot: TerminalFindRows?
    /// Output arrived since `snapshot` was read.
    private var snapshotStale = false
    /// The search running off the main thread, superseded by the next.
    private(set) var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Rows Ghostty dropped (a running total, negative): a search that finishes after a drop
    /// moves its matches by the rows dropped while it ran.
    private var droppedRows = 0
    /// The query the bar asked for last (the results may still be for an older one).
    private var query = ""

    /// New output while the bar is up: the next search reads the rows again.
    func outputArrived() {
        if isActive { snapshotStale = true }
    }

    /// One search of the redrawn screen per main-queue turn (``screenRedrawn()``).
    private lazy var redrawSearch = TerminalTurnCoalescer(schedule: TerminalMainQueue.schedule)

    /// A full-screen app drew its screen again (output, its scroll): its rows have no
    /// scrollback numbering to keep, so the matches are found again on the new screen and the
    /// highlights move with their text instead of staying on the rows they were on (Leo,
    /// 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
    /// scroll?"). One search per main-queue turn at most, near the selected match, without scrolling.
    func screenRedrawn() {
        guard isActive, !query.isEmpty else { return }
        redrawSearch.request { [weak self] in
            guard let self, isActive, !query.isEmpty else { return }
            snapshot = nil
            search(query, revealing: false, nearRow: results.selectedMatch?.row)
        }
    }

    fileprivate func search(_ query: String, revealing: Bool = true, nearRow: Int? = nil) {
        if !daemonUnavailable, let source = daemon() {
            return searchDaemon(query, source: source)
        }
        streamTask?.cancel()
        if snapshot == nil || snapshotStale, let source = readRows() {
            snapshot = TerminalFindRows(rows: source.rows, wraps: source.wraps, firstRow: source.firstRow, columns: source.columns)
            snapshotStale = false
        }
        self.query = query
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let droppedAtStart = droppedRows
        guard let rows = snapshot, !query.isEmpty else {
            results = TerminalFindResults()
            interaction?.updateResultCount()
            redraw()
            return
        }
        // The scan runs off the main thread on a copy of the rows; the newest search wins.
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                TerminalFindResults(rows: rows.rows, wraps: rows.wraps, firstRow: rows.firstRow, columns: rows.columns, query: query)
            }.value
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.results = found
            // The snapshot's rows are numbered as before any drop that happened meanwhile.
            let moved = self.droppedRows - droppedAtStart
            if moved != 0 { self.results.shiftRows(by: moved) }
            if let nearRow { self.results.select(nearestRow: nearRow + moved) }
            findLog.notice("find: \(found.matches.count, privacy: .public) matches in \(rows.rows.count, privacy: .public) rows")
            if revealing, let match = self.results.selectedMatch { self.reveal(match) }
            self.interaction?.updateResultCount()
            self.redraw()
        }
    }

    /// Asks the daemon, a page at a time, newest first: the count and the highlights grow as
    /// the pages arrive, the newest match is shown at once.
    private func searchDaemon(_ query: String, source: TerminalFindDaemonSource) {
        self.query = query
        searchTask?.cancel()
        streamTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        results = query.isEmpty ? TerminalFindResults() : TerminalFindResults(daemonQuery: query)
        interaction?.updateResultCount()
        redraw()
        guard !query.isEmpty else { return }
        let options = options
        streamTask = Task { [weak self] in
            var request = TerminalFindRequest(query: query, options: options)
            var first = true
            while !Task.isCancelled {
                let page: TerminalFindPage?
                do {
                    page = try await source.page(request)
                } catch {
                    findLog.error("find: terminal-find failed: \(String(describing: error), privacy: .public)")
                    self?.fallBackToMirror(query, generation: generation)
                    return
                }
                guard let self, generation == self.searchGeneration, !Task.isCancelled else { return }
                guard let page else { return self.fallBackToMirror(query, generation: generation) }
                guard let map = source.map() else { return self.fallBackToMirror(query, generation: generation) }
                self.results.append(page: page, map: map, columns: source.columns())
                if first, let match = self.results.selectedMatch { self.revealMatch(match) }
                first = false
                findLog.notice("find: daemon page \(page.hits.count, privacy: .public), \(self.results.matches.count, privacy: .public) so far")
                self.interaction?.updateResultCount()
                self.redraw()
                guard !self.results.isComplete, let before = page.nextBefore else { return }
                request = TerminalFindRequest(query: query, options: options, before: before, epoch: page.epoch)
            }
        }
    }

    /// The daemon cannot answer: search the mirror's rows, as before.
    private func fallBackToMirror(_ query: String, generation: Int) {
        guard generation == searchGeneration else { return }
        daemonUnavailable = true
        search(query)
    }

    /// The daemon failed or lacks the command: the rest of this find bar's life searches the mirror.
    private var daemonUnavailable = false

    /// Shows `match`: scrolls to it, or, when it is older than the mirror, loads its history first.
    private func revealMatch(_ match: TerminalFindResults.Match) {
        if match.isLoaded {
            revealWhenLoaded = false
            reveal(match)
        } else if let source = daemon(), let daemon = match.daemon, let map = source.map() {
            revealWhenLoaded = true
            let fromBottom = map.daemonRows - daemon.row
            if !source.loadHistory(daemon.row, fromBottom) { findLog.notice("find: history for an older match is busy") }
        }
    }

    /// A toggle changed: search again with the same query.
    fileprivate func restartSearch() {
        search(query)
        interaction?.updateResultCount()
    }

    fileprivate func highlightNext(forward: Bool) {
        results.step(forward: forward)
        if let match = results.selectedMatch { revealMatch(match) }
        interaction?.updateResultCount()
        redraw()
    }

    fileprivate func invalidate() {
        searchTask?.cancel()
        streamTask?.cancel()
        revealWhenLoaded = false
        daemonUnavailable = false
        searchGeneration += 1
        results = TerminalFindResults()
        query = ""
        snapshot = nil
        redraw()
    }

    /// The rows under the find changed wholesale (a full-screen app started or ended or
    /// was resized, the mirror was reset and replayed): search the new rows, near the same place.
    func rowsReplaced() {
        guard isActive, !query.isEmpty else { return }
        if results.fromDaemon, let source = daemon(), let map = source.map() {
            // The daemon's matches keep their rows; they are laid on the new mirror.
            results.remap(map, columns: source.columns())
            if revealWhenLoaded, let match = results.selectedMatch, match.isLoaded { revealMatch(match) }
            interaction?.updateResultCount()
            redraw()
            return
        }
        snapshot = nil
        search(query, revealing: false, nearRow: results.selectedMatch?.row)
    }

    /// Ghostty dropped its oldest rows: the matches keep their text.
    func shiftRows(by delta: Int) {
        droppedRows += delta
        guard !results.matches.isEmpty else { return }
        results.shiftRows(by: delta)
        interaction?.updateResultCount()
        redraw()
    }

    /// The system bar's Match Case and Full Words (Regular Expression is the controller's own).
    func setOptions(_ newOptions: TerminalFindOptions) {
        options.caseSensitive = newOptions.caseSensitive
        options.wholeWord = newOptions.wholeWord
    }

    /// Lays the highlights over the drawn rows again (the page moved, the document changed).
    func redraw() {
        guard let host = highlightHost() else {
            highlight.isHidden = true
            return
        }
        guard !results.matches.isEmpty else {
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

    #if DEBUG
    /// The highlights drawn now, one rect per row a match covers, in the host's coordinates
    /// (the highlight demo, TerminalHighlightScrollUITests).
    var drawnRects: [CGRect] {
        highlight.isHidden || highlight.superview == nil ? [] : highlight.rects.map { $0.0.offsetBy(dx: highlight.frame.minX, dy: highlight.frame.minY) }
    }

    /// Opens the bar and searches `query`, as typing it in the bar does (the highlight demo).
    func debugSearch(_ query: String) {
        present(terminalHadFocus: false)
        interaction?.searchText = query
        search(query)
    }
    #endif

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
        var found = TerminalFindOptions()
        found.caseSensitive = !(options?.stringCompareOptions.contains(.caseInsensitive) ?? true)
        found.wholeWord = options?.wordMatchMethod == .fullWord
        owner?.setOptions(found)
        owner?.search(query)
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        owner?.highlightNext(forward: direction == .forward)
    }

    override func invalidateFoundResults() {
        owner?.invalidate()
    }
}

/// The rows a find searches, copied once from Ghostty.
struct TerminalFindRows: Sendable {
    var rows: [String]
    var wraps: [Bool]
    var firstRow: Int
    var columns: Int
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

/// What the find bar needs of the daemon's `terminal-find` for the terminal on screen.
struct TerminalFindDaemonSource {
    /// One page of matches (nil: the session has no such command).
    var page: (TerminalFindRequest) async throws -> TerminalFindPage?
    /// The mirror's row mapping now (nil: unknown).
    func map() -> TerminalFindRowMap? { mapNow() }
    var mapNow: () -> TerminalFindRowMap?
    var columns: () -> Int
    /// Loads the history around a daemon row (its row, rows above the bottom); returns whether asked.
    var loadHistory: (_ daemonRow: Int, _ rowsFromBottom: Int) -> Bool
}
#endif

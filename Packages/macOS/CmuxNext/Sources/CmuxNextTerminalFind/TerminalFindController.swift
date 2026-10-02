public import Observation

/// One terminal's find bar: what it shows and how it drives the search.
///
/// Every find entrypoint (Cmd-F, Find Next/Previous, Hide Find Bar, Use
/// Selection for Find, copy mode's `/`, the bar's own keys and buttons)
/// goes through this controller, and Ghostty's search callbacks report back
/// to it. The query outlives a close, so reopening offers the last one.
///
/// ```swift
/// let find = TerminalFindController(target: session)
/// find.open()               // the bar shows and takes the keyboard
/// find.updateQuery("error") // live search; the first match is revealed
/// find.navigate(.next)      // steps up into scrollback, wrapping
/// find.close()              // highlights and selection go, the terminal is focused
/// ```
@MainActor
@Observable
public final class TerminalFindController {
    /// True while the find bar is shown.
    public private(set) var isPresented = false
    /// The text searched for. Kept after the bar closes.
    public private(set) var query = ""
    /// Number of matches, nil until the search reports it.
    public private(set) var total: Int?
    /// Ghostty's 0-based index of the selected match, nil when none is selected.
    public private(set) var selected: Int?
    /// Increments each time the bar should take the keyboard with its
    /// query selected; the view focuses its field on every change.
    public private(set) var focusRequest = 0

    /// What the count label shows.
    public var count: TerminalFindCount {
        TerminalFindCount(query: query, total: total, selected: selected)
    }

    /// The terminal searched. Weak: the session owns this controller.
    @ObservationIgnored public weak var target: (any TerminalFindTarget)?
    /// The query changed and no match has been selected for it yet.
    @ObservationIgnored private var revealPending = false
    /// The reveal's `navigate(.next)` was sent and its selection is awaited.
    @ObservationIgnored private var revealSent = false

    /// - Parameter target: The terminal to search; set later when it
    ///   needs this controller to exist first.
    public init(target: (any TerminalFindTarget)? = nil) {
        self.target = target
    }

    /// Shows the bar and asks it to take the keyboard with the query selected.
    ///
    /// - Parameter seed: Text to search for instead of the last query (the
    ///   selection, or a CLI argument). Nil or empty keeps the last query.
    public func open(seed: String? = nil) {
        let seed = seed.flatMap { $0.isEmpty ? nil : $0 }
        if isPresented {
            if let seed { updateQuery(seed) }
        } else {
            isPresented = true
            if let seed { query = seed }
            // Closing ended the search; reopening runs the query again.
            if !query.isEmpty { search(query) }
        }
        focusRequest += 1
    }

    /// Searches for `text` as the user types it. Empty text stops the search.
    public func updateQuery(_ text: String) {
        guard text != query else { return }
        // Ghostty matches case-insensitively and ignores a needle that
        // differs only in case, reporting nothing new: keep the results.
        let unchanged = isPresented && !text.isEmpty && text.lowercased() == query.lowercased()
        query = text
        if unchanged {
            target?.setSearchNeedle(text)
        } else {
            search(text)
        }
    }

    /// Selects the next or previous match. Opens the bar with the last
    /// query when it was closed.
    ///
    /// - Returns: False when there is no query to step through.
    @discardableResult
    public func navigate(_ direction: TerminalFindDirection) -> Bool {
        guard !query.isEmpty else { return false }
        guard isPresented else {
            open()
            return true
        }
        // The user is stepping now; a pending reveal would skip a match.
        revealPending = false
        revealSent = false
        target?.navigateSearch(direction)
        return true
    }

    /// Hides the bar, ends the search (removing every highlight), clears
    /// the terminal's selection and gives the keyboard back to the terminal.
    public func close() {
        guard isPresented else { return }
        isPresented = false
        resetResults()
        target?.endSearch()
        target?.clearSelection()
        target?.focusTerminal()
    }

    /// Ghostty started a search itself (its own `start_search` or
    /// `search_selection` keybind): show the bar with that needle.
    public func searchStarted(needle: String) {
        open(seed: needle)
    }

    /// Ghostty ended the search (`end_search`): hide the bar. The keyboard
    /// stays where it is.
    public func searchEnded() {
        isPresented = false
        resetResults()
    }

    /// Ghostty's match count for the current needle (nil when the search stopped).
    public func receiveTotal(_ total: Int?) {
        self.total = total
        guard let total, total > 0 else {
            // A new needle restarts the count at zero; a reveal sent for
            // the old one may have selected nothing, so it can go again.
            revealSent = false
            return
        }
        guard isPresented, revealPending, !revealSent, selected == nil else { return }
        // Select the first match so the count reads "1 of N" and Ghostty
        // scrolls it into view, even when it is up in scrollback.
        revealSent = true
        target?.navigateSearch(.next)
    }

    /// Ghostty's selected match index (nil when none is selected).
    public func receiveSelected(_ selected: Int?) {
        self.selected = selected
        guard selected != nil else { return }
        revealPending = false
        revealSent = false
    }

    private func search(_ text: String) {
        resetResults()
        revealPending = !text.isEmpty
        target?.setSearchNeedle(text)
    }

    private func resetResults() {
        total = nil
        selected = nil
        revealPending = false
        revealSent = false
    }
}

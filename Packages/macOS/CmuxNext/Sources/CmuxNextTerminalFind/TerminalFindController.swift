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
/// find.open()               // the bar shows and takes the keyboard before this returns
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
    public internal(set) var total: Int?
    /// Ghostty's 0-based index of the selected match, nil when none is selected.
    public internal(set) var selected: Int?
    /// Increments each time the bar should take the keyboard with its
    /// query selected; the view focuses its field on every change.
    public private(set) var focusRequest = 0

    /// The match kinds the daemon's history search honors.
    public internal(set) var options = TerminalFindOptions()
    /// The regex's compile error while it does not compile.
    public internal(set) var invalidPattern: String?
    /// Older rows are still being read: ``total`` only grows.
    public internal(set) var isSearching = false
    /// Matches come from the daemon's whole-history search, not Ghostty's screen search. False
    /// for a terminal with no daemon or one too old to serve `terminal-find`, which also have
    /// no case, whole-word or regex options.
    public internal(set) var searchesHistory = false

    /// What the count label shows.
    public var count: TerminalFindCount {
        TerminalFindCount(query: query, total: total, selected: selected, searching: isSearching, invalidPattern: invalidPattern)
    }

    /// Whether the bar offers the case, whole-word and regex toggles.
    public var offersOptions: Bool { target?.historyFind != nil && !historyUnavailable }

    /// The terminal searched. Weak: the session owns this controller.
    @ObservationIgnored public weak var target: (any TerminalFindTarget)?
    /// The query changed and no match has been selected for it yet.
    @ObservationIgnored var revealPending = false
    /// The reveal's `navigate(.next)` was sent and its selection is awaited.
    @ObservationIgnored private var revealSent = false
    /// The daemon's matches so far, newest first, and the terminal's width.
    @ObservationIgnored var matches: [TerminalFindMatch] = []
    @ObservationIgnored var columns = 80
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Bumped by every new search; a page that comes back for an older one is dropped.
    @ObservationIgnored var searchGeneration = 0
    /// The daemon could not serve a search (too old): Ghostty's screen search takes over.
    @ObservationIgnored var historyUnavailable = false

    /// - Parameter target: The terminal to search; set later when it
    ///   needs this controller to exist first.
    public init(target: (any TerminalFindTarget)? = nil) {
        self.target = target
    }

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    /// Shows the bar and, for the user, asks it to take the keyboard with
    /// the query selected.
    ///
    /// - Parameter seed: Text to search for instead of the last query (the
    ///   selection, or a CLI argument). Nil or empty keeps the last query.
    /// - Parameter takeFocus: False for a socket or CLI run that may not
    ///   change the user's view: the bar shows without taking the keyboard.
    public func open(seed: String? = nil, takeFocus: Bool = true) {
        let seed = seed.flatMap { $0.isEmpty ? nil : $0 }
        if isPresented {
            if let seed { updateQuery(seed) }
        } else {
            isPresented = true
            if let seed { query = seed }
            // Closing ended the search; reopening runs the query again.
            if !query.isEmpty { search(query) }
        }
        if takeFocus { focusRequest += 1 }
        // Not left to observation: its change callback runs a main-actor hop
        // later, after keys already queued behind Cmd-F went to the terminal.
        target?.showFindBar()
    }

    /// Searches for `text` as the user types it. Empty text stops the search.
    public func updateQuery(_ text: String) {
        guard text != query else { return }
        // Ghostty matches case-insensitively and ignores a needle that
        // differs only in case, reporting nothing new: keep the results.
        let unchanged = !historyActive && isPresented && !text.isEmpty && text.lowercased() == query.lowercased()
        query = text
        if unchanged {
            target?.setSearchNeedle(text)
        } else {
            search(text)
        }
    }

    /// Selects the next or previous match. A closed bar opens instead: with
    /// the last query, else as Find does (with `seed`, the selection).
    ///
    /// - Parameters:
    ///   - seed: The query a bar opening with no last query starts with.
    ///   - takeFocus: Whether opening the bar may take the keyboard
    ///     (see ``open(seed:takeFocus:)``).
    public func navigate(_ direction: TerminalFindDirection, seed: @autoclosure () -> String? = nil, takeFocus: Bool = true) {
        guard isPresented else { return open(seed: query.isEmpty ? seed() : nil, takeFocus: takeFocus) }
        guard !query.isEmpty else { return }
        // The user is stepping now; a pending reveal would skip a match.
        revealPending = false
        revealSent = false
        if searchesHistory { return stepHistory(direction) }
        target?.navigateSearch(direction)
    }

    /// Hides the bar and ends the search, removing every highlight. For
    /// the user it also clears the terminal's selection (unless copy mode
    /// owns it) and gives the keyboard back to the terminal.
    ///
    /// - Parameter restoringFocus: False for a socket or CLI run that may
    ///   not change the user's view: focus and the selection stay as they are.
    public func close(restoringFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        resetResults()
        target?.endSearch()
        guard restoringFocus, let target else { return }
        if !target.isSelectionPinned { target.clearSelection() }
        target.focusTerminal()
    }

    /// The terminal swapped in a fresh surface (a reconnect replay), which
    /// has no search: while the bar is open, search the new one again.
    public func surfaceReplaced() {
        guard isPresented, !query.isEmpty else { return }
        search(query)
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
        guard !searchesHistory else { return } // the daemon's count is the one shown
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
        guard !searchesHistory else { return }
        self.selected = selected
        guard selected != nil else { return }
        revealPending = false
        revealSent = false
    }

    func search(_ text: String) {
        resetResults()
        if historyActive { return searchHistory() }
        revealPending = !text.isEmpty
        target?.setSearchNeedle(text)
    }

    /// Whether this search goes to the daemon.
    var historyActive: Bool { target?.historyFind != nil && !historyUnavailable }

    func resetResults() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        matches = []
        invalidPattern = nil
        isSearching = false
        searchesHistory = false
        total = nil
        selected = nil
        revealPending = false
        revealSent = false
    }
}

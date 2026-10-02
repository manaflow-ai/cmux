import CmuxNextTerminalFind

/// Stands in for a terminal's Ghostty search. It behaves like the pinned
/// Ghostty (`src/terminal/search`): results arrive later on the search
/// thread, so events queue until ``flush()``; a new needle reports a zero
/// total before the real one; match 0 is the newest and selection wraps at
/// both ends; the first `navigate` selects match 0 (next) or the oldest
/// (previous); a needle differing only in ASCII case is ignored.
@MainActor
final class GhosttySearchStub: TerminalFindTarget {
    enum Call: Equatable {
        case needle(String)
        case navigate(TerminalFindDirection)
        case endSearch
        case clearSelection
        case focusTerminal
    }

    weak var controller: TerminalFindController?
    /// Matches per lowercased needle.
    var matches: [String: Int]
    /// Totals reported on the way to the final one (Ghostty counts
    /// screen and scrollback in steps).
    var partialTotals: [Int] = []
    /// Index of the oldest match still on screen; anything higher is
    /// up in scrollback until Ghostty scrolls to it.
    var lastVisibleMatch = 0

    private(set) var calls: [Call] = []
    private(set) var needle: String?
    private(set) var selectedMatch: Int?
    /// The match Ghostty scrolled the viewport to, when it had to.
    private(set) var scrolledToMatch: Int?
    private(set) var hasSelection = true
    private var pending: [(TerminalFindController) -> Void] = []

    var isSearching: Bool { needle != nil }

    init(matches: [String: Int]) {
        self.matches = matches
    }

    func setSearchNeedle(_ needle: String) {
        calls.append(.needle(needle))
        if needle.isEmpty {
            stop()
            return
        }
        if let current = self.needle, current.lowercased() == needle.lowercased() { return }
        self.needle = needle
        selectedMatch = nil
        let total = matches[needle.lowercased()] ?? 0
        pending.append { $0.receiveTotal(0) }
        pending.append { $0.receiveSelected(nil) }
        for partial in partialTotals where partial < total { pending.append { $0.receiveTotal(partial) } }
        pending.append { $0.receiveTotal(total) }
    }

    func navigateSearch(_ direction: TerminalFindDirection) {
        calls.append(.navigate(direction))
        guard let needle else { return }
        let total = matches[needle.lowercased()] ?? 0
        guard total > 0 else { return }
        let next: Int
        switch (selectedMatch, direction) {
        case (nil, .next): next = 0
        case (nil, .previous): next = total - 1
        case (let current?, .next): next = current + 1 >= total ? 0 : current + 1
        case (let current?, .previous): next = current == 0 ? total - 1 : current - 1
        }
        selectedMatch = next
        if next > lastVisibleMatch { scrolledToMatch = next }
        pending.append { $0.receiveSelected(next) }
    }

    func endSearch() {
        calls.append(.endSearch)
        stop()
    }

    func clearSelection() {
        calls.append(.clearSelection)
        hasSelection = false
    }

    func focusTerminal() {
        calls.append(.focusTerminal)
    }

    /// Delivers every queued search event, as the main actor would.
    func flush() {
        guard let controller else { return }
        while !pending.isEmpty {
            pending.removeFirst()(controller)
        }
    }

    private func stop() {
        guard needle != nil else { return }
        needle = nil
        selectedMatch = nil
        pending.append { $0.receiveTotal(nil) }
        pending.append { $0.receiveSelected(nil) }
    }
}

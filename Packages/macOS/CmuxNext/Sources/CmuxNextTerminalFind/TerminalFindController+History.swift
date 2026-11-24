import Foundation

/// The daemon's whole-history search behind the bar: the query goes out as you type (debounced), pages
/// stream in newest first and grow the count, and a step selects the match in the terminal's own rows.
/// Matching and paging are Rust's (`terminal-find`); this drives requests and keeps the position.
extension TerminalFindController {
    /// The most matches kept: the daemon's own cap.
    static let matchLimit = 10_000
    /// The pause after the last keystroke before a search goes out.
    static let debounce: Duration = .milliseconds(80)

    /// Turns a toggle on or off and searches again.
    public func setOption(_ option: WritableKeyPath<TerminalFindOptions, Bool>, _ on: Bool) {
        guard options[keyPath: option] != on else { return }
        options[keyPath: option] = on
        if isPresented, !query.isEmpty { search(query) }
    }

    func searchHistory() {
        guard !query.isEmpty else { return }
        searchesHistory = true
        isSearching = true
        revealPending = true
        let generation = searchGeneration
        // task-owner: resetResults cancels it (a new query, a close); a stale page checks `generation`.
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce) // wakeup-allow: the one-shot debounce deadline, cancelled by the next keystroke
            guard !Task.isCancelled else { return }
            await self?.streamPages(generation: generation)
        }
    }

    private func streamPages(generation: Int) async {
        guard let history = target?.historyFind else { return }
        var request = TerminalFindPageRequest(query: query, options: options)
        var first = true
        while generation == searchGeneration, !Task.isCancelled {
            let page: TerminalFindPage
            do {
                page = try await history.page(request)
            } catch {
                guard generation == searchGeneration, !Task.isCancelled else { return }
                if first {
                    // No daemon search (an older daemon): Ghostty's screen search takes over.
                    historyUnavailable = true
                    search(query)
                } else {
                    isSearching = false
                }
                return
            }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            first = false
            if let reason = page.invalidPattern {
                invalidPattern = reason
                total = 0
                isSearching = false
                return
            }
            if page.restarted {
                matches = []
                selected = nil
            }
            columns = page.columns
            matches += page.matches.prefix(Self.matchLimit - matches.count)
            total = matches.count
            if revealPending, selected == nil, !matches.isEmpty { select(0) }
            guard let next = page.nextBefore, matches.count < Self.matchLimit else { break }
            request.before = next
            request.epoch = page.epoch
        }
        guard generation == searchGeneration else { return }
        total = matches.count
        isSearching = false
    }

    /// Moves to the next (older) or previous (newer) match, wrapping once every page is in.
    func stepHistory(_ direction: TerminalFindDirection) {
        guard !matches.isEmpty else { return }
        let last = matches.count - 1
        let current = selected ?? (direction == .next ? -1 : 0)
        switch direction {
        case .next:
            if current < last { select(current + 1) } else if !isSearching { select(0) }
        case .previous:
            select(current > 0 ? current - 1 : (isSearching ? 0 : last))
        }
    }

    /// Selects match `index` and reveals it. A match the mirror cannot show (its history is shorter,
    /// the row changed) falls back to Ghostty's search for what is on screen.
    private func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selected = index
        revealPending = false
        let match = matches[index]
        if target?.revealHistoryMatch(match, columns: columns) != true {
            target?.setSearchNeedle(match.text)
            target?.navigateSearch(.next)
        }
    }
}

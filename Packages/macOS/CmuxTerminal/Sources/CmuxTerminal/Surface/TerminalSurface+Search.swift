public import Foundation

// MARK: - Terminal find/search orchestration

extension TerminalSurface {
    /// Starts terminal find for this surface, or refocuses the overlay when a
    /// search is already active, then notifies the caller so it can move
    /// keyboard focus into the find field.
    ///
    /// The orchestration sequences three legacy paths byte-for-byte:
    /// 1. An existing `searchState` is reused (its needle is replaced only when
    ///    a non-empty `initialNeedle` is supplied) and the notifier fires.
    /// 2. Otherwise the Ghostty `start_search` binding action is attempted; on
    ///    success the search-state seeding + notify is deferred one main-queue
    ///    hop so it observes whatever state Ghostty installed.
    /// 3. If the binding action does not handle it, search state is seeded
    ///    synchronously and the notifier fires.
    ///
    /// Isolation note: `searchState` carries the legacy main-thread-only
    /// contract as compiler-enforced isolation, so this entry is `@MainActor`;
    /// every caller already runs on the main actor.
    ///
    /// - Parameters:
    ///   - initialNeedle: Seed needle for a freshly created search, and the
    ///     replacement needle when reusing an existing search (empty leaves the
    ///     existing needle untouched).
    ///   - searchFocusNotifier: Invoked with this surface once search state is
    ///     ready, so the caller can drive find-field focus. The caller owns the
    ///     concrete focus mechanism (e.g. the `.ghosttySearchFocus`
    ///     notification) so no app-target constant leaks into the package.
    /// - Returns: Always `true`; the surface is left in a searchable state on
    ///   every path.
    @MainActor
    @discardableResult
    public func startOrFocusSearch(
        initialNeedle: String = "",
        searchFocusNotifier: @escaping (TerminalSurface) -> Void
    ) -> Bool {
        if searchState != nil {
            if !initialNeedle.isEmpty { searchState?.needle = initialNeedle }
            searchFocusNotifier(self)
            return true
        }
        if performBindingAction("start_search") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let searchState = self.searchState {
                    if !initialNeedle.isEmpty { searchState.needle = initialNeedle }
                } else {
                    self.searchState = TerminalSurface.SearchState(needle: initialNeedle)
                }
                searchFocusNotifier(self)
            }
            return true
        }
        searchState = TerminalSurface.SearchState(needle: initialNeedle)
        searchFocusNotifier(self)
        return true
    }
}

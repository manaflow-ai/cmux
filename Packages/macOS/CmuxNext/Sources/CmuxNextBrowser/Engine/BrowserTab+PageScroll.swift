extension BrowserTab {
    /// Scrolls the page by keyboard (``BrowserPageScroll``) in either engine, as cmux's own work:
    /// no user gesture. A closed or sleeping tab scrolls nothing. `j` and `k` start a scroll the
    /// page's frame clock drives until key-up; `releasing` ends it at once (a tap, the palette),
    /// in the same task so the release never runs before the start. `topSpeed` is a held key's (px/s).
    public func scroll(_ scroll: BrowserPageScroll, releasing: Bool = false, topSpeed: Double = BrowserPageScroll.topSpeed(keyRepeatInterval: 0)) {
        // task-owner: fire-and-forget page scroll; nothing waits on it.
        Task {
            _ = try? await evaluate(scroll.script(topSpeed: topSpeed), world: .isolated, gesture: .cmux)
            if releasing, let letter = scroll.letter { _ = try? await evaluate(BrowserPageScroll.release(letter), world: .isolated, gesture: .cmux) }
        }
    }

    /// Ends the held scroll `scroll` started (its key went up).
    public func releaseScroll(_ scroll: BrowserPageScroll) {
        guard let letter = scroll.letter else { return }
        // task-owner: fire-and-forget; an ended or missing scroll ignores it.
        Task { _ = try? await evaluate(BrowserPageScroll.release(letter), world: .isolated, gesture: .cmux) }
    }
}

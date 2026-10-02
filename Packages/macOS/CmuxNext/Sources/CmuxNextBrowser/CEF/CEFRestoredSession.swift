import Foundation

/// A Chromium tab's back/forward entries saved before a relaunch
/// (plans/cmux-next/browser.md, "Session history across relaunch"). A
/// restored page shows one saved entry and goes back to its scroll
/// position; the saved entries around it are `history`. Chromium cannot
/// take entries back, so Back past Chromium's own first entry replaces that
/// entry with the saved one, and the saved forward entries sit right after
/// it: from there Forward steps through them before Chromium's own. A new
/// navigation of the user's drops the saved forward entries.
final class CEFRestoredSession {
    private weak var tab: CEFTab?
    /// The saved entries Chromium no longer has; nil when there are none.
    private(set) var history: BrowserRestoredHistory?
    /// One step at a time: a second press while the first measures the
    /// scroll position waits for its page.
    private(set) var isStepping = false
    /// The saved entry a replace is loading, until it commits.
    private var restoringEntry: BrowserSavedEntry?
    /// Where to scroll the page once its document loads.
    private var pendingScrollY: Double?
    /// Scroll positions of pages in the tab's history, by URL: saved ones
    /// and those measured since, for the history saved at quit.
    private var knownScrollY: [URL: Double] = [:]

    init(tab: CEFTab) {
        self.tab = tab
    }

    /// `entries[current]` is the page the tab shows; the others become its
    /// Back and Forward entries, and the page scrolls back to its position.
    func restore(_ entries: [BrowserSavedEntry], current: Int) {
        guard let tab, entries.indices.contains(current), !tab.isClosed else { return }
        history = BrowserRestoredHistory(entries: entries, current: current)
        for entry in entries where entry.scrollY != nil {
            knownScrollY[entry.url] = entry.scrollY
        }
        if let y = entries[current].scrollY, y > 0 {
            if case .finished = tab.state.phase { restoreScroll(y) } else { pendingScrollY = y }
        }
        applyAvailability()
    }

    /// The tab's entries as they are saved, with the scroll positions it
    /// knows; `measuringScroll` also asks the shown page.
    func savedSession(measuringScroll: Bool) async -> BrowserSavedSession? {
        guard let tab else { return nil }
        if measuringScroll, pendingScrollY == nil, restoringEntry == nil, let url = tab.state.url, let y = await tab.currentScrollY() {
            // The page may have moved on while it answered.
            if tab.state.url == url { knownScrollY[url] = y }
        }
        guard let url = tab.state.url else { return nil }
        let shown = BrowserNavigationEntry(url: url, title: tab.state.title)
        var session = (history ?? .empty).session(around: tab.nativeNavigationList(), shown: shown)
        guard session.entries.indices.contains(session.current) else { return nil }
        for index in session.entries.indices where session.entries[index].scrollY == nil {
            session.entries[index].scrollY = knownScrollY[session.entries[index].url]
        }
        knownScrollY = knownScrollY.filter { known in session.entries.contains { $0.url == known.key } }
        return session
    }

    /// Back and Forward are offered when Chromium or the saved entries have one.
    func applyAvailability() {
        guard let tab else { return }
        tab.machine.apply(.historyChanged(canGoBack: tab.nativeHistory.back || !(history?.back.isEmpty ?? true),
                                          canGoForward: tab.nativeHistory.forward || !(history?.forward.isEmpty ?? true)))
    }

    /// `offset` counts in the merged list. Saved entries are reached from
    /// Chromium's first entry; from another entry the jump stops at the
    /// first one, and from the first one a jump past the saved forward
    /// entries stops at the last of them (Chromium's later entries follow).
    func goToEntry(offset: Int) -> Bool {
        guard let tab, let saved = history else { return false }
        let native = tab.nativeNavigationList()
            ?? BrowserNavigationList(entries: [BrowserNavigationEntry(url: tab.state.url, title: tab.state.title)], current: 0)
        let first = saved.back.count, lastSaved = saved.back.count + saved.forward.count
        let target = saved.position(of: native) + offset
        guard target >= 0, target < native.entries.count + lastSaved else { return false }
        let reachesSaved = target < first || (target > first && (target <= lastSaved || !saved.forward.isEmpty))
        if reachesSaved, native.current != 0 { return tab.goToNativeEntry(offset: -native.current) }
        if reachesSaved { return step(by: min(target, lastSaved) - first) }
        let index = target == first ? 0 : target - lastSaved
        return tab.goToNativeEntry(offset: index - native.current)
    }

    /// Moves `offset` saved entries back (negative) or forward from
    /// Chromium's first entry. False when there are not that many.
    func step(by offset: Int) -> Bool {
        guard let tab, let saved = history, offset != 0, let shownURL = tab.state.url else { return false }
        guard offset < 0 ? saved.back.count >= -offset : saved.forward.count >= offset else { return false }
        guard !isStepping else { return true }
        isStepping = true
        let title = tab.state.title
        Task { @MainActor [weak self, weak tab] in
            guard let self else { return }
            defer { isStepping = false }
            let shown = BrowserSavedEntry(url: shownURL, title: title, scrollY: await tab?.currentScrollY())
            if let y = shown.scrollY { knownScrollY[shownURL] = y }
            guard var saved = history, let tab, !tab.isClosed else { return }
            guard let target = offset < 0 ? saved.goBack(-offset, from: shown) : saved.goForward(offset, from: shown) else { return }
            history = saved.isEmpty ? nil : saved
            applyAvailability()
            await show(target, in: tab)
        }
        return true
    }

    /// Replaces the shown page with a saved entry (`location.replace` keeps
    /// Chromium's list as it is); a page that runs no script loads it.
    private func show(_ entry: BrowserSavedEntry, in tab: CEFTab) async {
        restoringEntry = entry
        let literal = Self.javaScriptString(entry.url.absoluteString)
        do {
            _ = try await tab.evaluate("location.replace(\(literal)); true", world: .isolated)
        } catch {
            tab.load(entry.url)
        }
    }

    /// A navigation committed: a replace this tab started shows its saved
    /// entry's scroll position once loaded.
    func navigationCommitted() {
        guard let entry = restoringEntry else { return }
        restoringEntry = nil
        pendingScrollY = entry.scrollY
    }

    /// The document loaded: scroll a restored page back to where it was,
    /// and drop the saved forward entries once the user went somewhere new
    /// (Chromium left its first entry, the one the saved ones sit around).
    func documentLoaded() {
        if let y = pendingScrollY {
            pendingScrollY = nil
            if y > 0 { restoreScroll(y) }
        }
        guard let tab, var saved = history, !saved.forward.isEmpty, restoringEntry == nil,
              tab.nativeHistory.back else { return }
        saved.dropForward()
        history = saved.isEmpty ? nil : saved
        applyAvailability()
    }

    /// Scrolls to `y` once the page is tall enough (up to 3 s while it lays
    /// out), and stops as soon as the user scrolls or types.
    private func restoreScroll(_ y: Double) {
        let script = """
        (function (y) {
          var moved = false, tries = 0;
          var stop = function () { moved = true; };
          addEventListener('wheel', stop, { once: true, passive: true });
          addEventListener('keydown', stop, { once: true });
          addEventListener('touchstart', stop, { once: true, passive: true });
          (function step() {
            if (moved) return;
            var room = document.documentElement.scrollHeight - innerHeight;
            scrollTo(0, Math.min(y, Math.max(room, 0)));
            if (room < y && tries++ < 30) setTimeout(step, 100);
          })();
          return true;
        })(\(y))
        """
        Task { @MainActor [weak tab] in _ = try? await tab?.evaluate(script, world: .isolated) }
    }

    /// `text` as a JavaScript string literal.
    static func javaScriptString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

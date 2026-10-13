import Foundation

/// What a tab gives `BrowserRestoredSession`: its engine's own back/forward
/// list and commands, and its page (`CEFRestoredSessionHost`,
/// `WebKitRestoredSessionHost`, outside the tab types).
protocol BrowserRestoredSessionHost {
    var state: BrowserTabState { get }
    var isClosed: Bool { get }
    /// Whether the engine's own list has a Back and a Forward entry.
    var nativeHistory: (back: Bool, forward: Bool) { get }
    /// The engine's own back/forward list; nil when it cannot list it.
    func nativeNavigationList() -> BrowserNavigationList?
    func goToNativeEntry(offset: Int) -> Bool
    /// Shows Back and Forward as available or not.
    func applyHistoryAvailability(canGoBack: Bool, canGoForward: Bool)
    func currentScrollY() async -> Double?
    func evaluate(_ script: String, world: BrowserScriptWorld) async throws -> BrowserJSValue
    func load(_ url: URL)
}

/// A tab's back/forward entries saved before a relaunch
/// (plans/cmux-next/browser.md, "Session history across relaunch"). A
/// restored page shows one saved entry and goes back to its scroll
/// position; the saved entries around it are `history`. Neither engine can
/// take entries back, so Back past the engine's own first entry replaces
/// that entry with the saved one, and the saved forward entries sit right
/// after it: from there Forward steps through them before the engine's
/// own. A new navigation of the user's drops the saved forward entries.
class BrowserRestoredSession {
    /// The tab's host, nil once the tab is gone.
    private let host: () -> (any BrowserRestoredSessionHost)?
    private var tab: (any BrowserRestoredSessionHost)? { host() }
    /// The saved entries the engine no longer has; nil when there are none.
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

    init(host: @escaping () -> (any BrowserRestoredSessionHost)?) {
        self.host = host
    }

    /// `entries[current]` is the page the tab shows; the others become its
    /// Back and Forward entries, and the page scrolls back to its position.
    func restore(_ entries: [BrowserSavedEntry], current: Int) {
        guard let tab, entries.indices.contains(current), !tab.isClosed else { return }
        // A page that kept the engine's own list (woken from hibernation,
        // `BrowserRestoreState`) has some of these entries already: only
        // the saved ones before that list come back.
        if let native = tab.nativeNavigationList(), native.entries.count > 1 {
            return restoreAround(native, entries: entries, current: current)
        }
        // Only web pages come back as Back and Forward entries: a replace
        // to another scheme may not navigate at all.
        let kept = entries.indices.filter { $0 == current || Self.isWebPage(entries[$0].url) }
        let current = kept.firstIndex(of: current) ?? 0
        let entries = kept.map { entries[$0] }
        history = BrowserRestoredHistory(entries: entries, current: current)
        for entry in entries where entry.scrollY != nil {
            knownScrollY[entry.url] = entry.scrollY
        }
        if let y = entries[current].scrollY, y > 0 {
            if case .finished = tab.state.phase { restoreScroll(y) } else { pendingScrollY = y }
        }
        applyAvailability()
    }

    /// Scrolls the shown page to `y` once its document loads: a page whose
    /// engine restored its own history, which may keep an older position
    /// for the page shown than the one saved at quit.
    func scrollOnLoad(to y: Double) {
        guard y > 0, let tab, !tab.isClosed else { return }
        if case .finished = tab.state.phase { restoreScroll(y) } else { pendingScrollY = y }
    }

    /// `native` is the run of saved entries that ends or contains `current`:
    /// the saved entries before its first become Back entries before the
    /// engine's own. A list that does not match the saved one adds nothing.
    private func restoreAround(_ native: BrowserNavigationList, entries: [BrowserSavedEntry], current: Int) {
        let start = current - native.current
        guard start > 0, start + native.entries.count <= entries.count,
              native.entries.indices.allSatisfy({ native.entries[$0].url == entries[start + $0].url }) else { return }
        let back = entries[..<start].filter { Self.isWebPage($0.url) }
        history = BrowserRestoredHistory(entries: back + [entries[current]], current: back.count)
        for entry in back where entry.scrollY != nil {
            knownScrollY[entry.url] = entry.scrollY
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

    /// The engine's list with the saved entries around it.
    func navigationList() -> BrowserNavigationList? {
        guard let tab else { return nil }
        let native = tab.nativeNavigationList()
        guard let saved = history, let url = tab.state.url else { return native }
        return saved.merged(with: native, shown: BrowserNavigationEntry(url: url, title: tab.state.title))
    }

    /// The engine's Back or Forward state changed.
    func syncAvailability() {
        applyAvailability()
        dropForwardIfLeftFirstEntry()
    }

    /// Back and Forward are offered when the engine or the saved entries have one.
    func applyAvailability() {
        guard let tab else { return }
        tab.applyHistoryAvailability(canGoBack: tab.nativeHistory.back || !(history?.back.isEmpty ?? true),
                                     canGoForward: tab.nativeHistory.forward || !(history?.forward.isEmpty ?? true))
    }

    /// `offset` counts in the merged list. Saved entries are reached from
    /// the engine's first entry; from another entry the jump stops at the
    /// first one, and from the first one a jump past the saved forward
    /// entries stops at the last of them (the engine's later entries follow).
    func goToEntry(offset: Int) -> Bool {
        guard let tab else { return false }
        guard let saved = history else { return tab.goToNativeEntry(offset: offset) }
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
    /// the engine's first entry. False when there are not that many.
    func step(by offset: Int) -> Bool {
        guard let tab, let saved = history, offset != 0, let shownURL = tab.state.url else { return false }
        guard offset < 0 ? saved.back.count >= -offset : saved.forward.count >= offset else { return false }
        guard !isStepping else { return true }
        isStepping = true
        let title = tab.state.title
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isStepping = false }
            let shown = BrowserSavedEntry(url: shownURL, title: title, scrollY: await self.tab?.currentScrollY())
            if let y = shown.scrollY { knownScrollY[shownURL] = y }
            guard var saved = history, let tab = self.tab, !tab.isClosed else { return }
            guard let target = offset < 0 ? saved.goBack(-offset, from: shown) : saved.goForward(offset, from: shown) else { return }
            history = saved.isEmpty ? nil : saved
            applyAvailability()
            await show(target, in: tab)
        }
        return true
    }

    /// Replaces the shown page with a saved entry (`location.replace` keeps
    /// the engine's list as it is); a page that runs no script loads it.
    private func show(_ entry: BrowserSavedEntry, in tab: any BrowserRestoredSessionHost) async {
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
    func navigationCommitted(url: URL?) {
        guard let entry = restoringEntry else { return }
        restoringEntry = nil
        // Another page committed (the replace did not navigate): its scroll
        // position is not the saved entry's.
        if url == entry.url { pendingScrollY = entry.scrollY }
    }

    /// The document loaded: scroll a restored page back to where it was.
    func documentLoaded() {
        if let y = pendingScrollY {
            pendingScrollY = nil
            if y > 0 { restoreScroll(y) }
        }
        dropForwardIfLeftFirstEntry()
    }

    /// Drops the saved forward entries once the user went somewhere new:
    /// the engine left its first entry, the one the saved ones sit around
    /// (the engine's Back state, which a same-document navigation also sets).
    func dropForwardIfLeftFirstEntry() {
        guard let tab, var saved = history, !saved.forward.isEmpty, restoringEntry == nil,
              tab.nativeHistory.back else { return }
        saved.dropForward()
        history = saved.isEmpty ? nil : saved
        applyAvailability()
    }

    /// Scrolls to `y` once the page is tall enough (up to 3 s while it lays
    /// out), then holds it for 1.5 s (an engine restoring its own history
    /// can put back an older position after the load), and stops as soon as
    /// the user scrolls, clicks or types.
    private func restoreScroll(_ y: Double) {
        let script = """
        (function (y) {
          var moved = false, tries = 0, held = 0;
          var stop = function () { moved = true; };
          addEventListener('wheel', stop, { once: true, passive: true });
          addEventListener('keydown', stop, { once: true });
          addEventListener('mousedown', stop, { once: true });
          addEventListener('touchstart', stop, { once: true, passive: true });
          (function step() {
            if (moved) return;
            var room = document.documentElement.scrollHeight - innerHeight;
            var target = Math.min(y, Math.max(room, 0));
            if (Math.abs(scrollY - target) > 1) scrollTo(0, target);
            if (room < y && tries++ < 30) return setTimeout(step, 100);
            if (held++ < 15) setTimeout(step, 100);
          })();
          return true;
        })(\(y))
        """
        Task { @MainActor [weak self] in _ = try? await self?.tab?.evaluate(script, world: .isolated) }
    }

    static func isWebPage(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    /// `text` as a JavaScript string literal.
    static func javaScriptString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

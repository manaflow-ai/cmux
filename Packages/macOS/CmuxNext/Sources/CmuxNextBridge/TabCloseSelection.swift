import CmuxNextDesign
public import CmuxNextTabs

/// The close-selection rule's state for the tabs of one window's panes (plans/cmux-next/close-focus.md,
/// "One close-selection rule"; Lawrence 2026-11-10: "tabs also follow Chrome's rule"). One pane's tabs are
/// one strip. It is the same state type the workspaces use (`CloseSelection`, cmux-focus-core's
/// `close_selection::Openers`); nothing here decides a successor. One instance per window, owned by the
/// window's ``TabSelectionMemory``: a tab's selection is the window's own.
///
/// A tab a person makes in the foreground (Cmd-T, the +, a New Tab action) keeps an opener: the tab its
/// pane showed before. Its lifetime follows the placement: put right after the current tab (the default),
/// the relation lasts as a link tab's does, until the person selects an unrelated tab; put at the end or
/// the start, it is the quick look-up and ends when the pane's selection leaves the new tab. A tab a link
/// or an action inside another tab makes keeps that tab as its opener (``made(_:from:in:quick:foreground:)``).
/// A tab made by the CLI, the socket, MCP, a script, a restore, a move or a drag has none. A relation never
/// crosses panes: a tab that leaves its pane (closed, or moved) leaves the state.
///
/// A tab that takes another tab's place (a stand-in's daemon tab, what a New Tab page turns into) is the
/// same item: the state keeps the first id and maps the later ones to it.
///
/// Cost: with no relation held, a selection change is two emptiness checks and one dictionary read, and a
/// close picks by position over the pane's tabs. With some held, each call asks about the tabs of those
/// relations and, at most, the pane's own tabs. No call walks a window or the session.
public final class TabCloseSelection {
    private let openers = CloseSelection<String>()
    /// The pane of each tab `openers` holds a number for (a relation's child or its opener), by the id the state knows.
    private var home: [String: String] = [:]
    /// A new foreground tab a pane is about to select: the tab it showed at the press, the tabs it listed then, the lifetime.
    private var expected: [String: (opener: String, listed: Set<String>, quick: Bool, link: Bool)] = [:]
    /// A person's selection that is about to land (a click, a shortcut, the palette, the switcher).
    private var gesture: (pane: String, tab: String)?
    /// The selection a close is about to cause: never a gesture (``closeSelects(_:in:)``).
    private var closePick: (pane: String, tab: String)?
    /// A close's own selection runs (``closeSelects(_:)``): it is not a move the rule hears of.
    private var inClosePick = false
    /// A tab that took another's place: its id to the id the state knows, and back.
    private var known: [String: String] = [:]
    private var shownAs: [String: String] = [:]

    public init() {}

    /// No opener relation is held: every pick is by position.
    public var isEmpty: Bool { home.isEmpty }

    /// A person asked for a new tab in the foreground of `pane`, which shows `opener` and lists `listed`.
    /// The pane's next selection takes it: a tab not in `listed`, selected while the pane still shows
    /// `opener`, gets `opener` as its opener. `quick`: the tab is put away from the current one (at the
    /// end or the start), so the relation ends on any selection change. `link`: a link in `opener` asked, not a
    /// new-tab key (a page that shows before its store tab exists, so ``made(_:from:in:quick:foreground:)`` has no
    /// tab to name yet): a foreground task tab, which first ends the pane's older relations, as a link's web tab does.
    public func expect(in pane: String, opener: String, listed: [String], quick: Bool, link: Bool = false) {
        expected[pane] = (opener, Set(listed), quick, link)
    }

    /// A person chose `tab` in `pane` (a click, a shortcut, the palette, the switcher); the selection
    /// itself follows (``TabSelectionMemory/select(_:in:standIn:)``). Not for a close's own selection, the
    /// CLI, the socket or a script. With no relation held it keeps nothing.
    public func personSelects(_ tab: String, in pane: String) {
        if let pick = closePick, pick.pane == pane {
            closePick = nil
            if pick.tab == tab { return }
        }
        guard !home.isEmpty else { return }
        gesture = (pane, tab)
    }

    /// The app is about to select `tab` in `pane` because the selected tab closes (a tab group's close moves
    /// the selection at the press): that selection is the close's, not a person's gesture. The mark ends at
    /// the pane's next selection, whoever makes it (a script's close never asks ``personSelects(_:in:)``), so
    /// a later choice of the person is a gesture again.
    public func closeSelects(_ tab: String, in pane: String) {
        closePick = home.isEmpty ? nil : (pane, tab)
    }

    /// Runs the selection a close causes (the pick after the selected tab left, or a move at the press of a
    /// close). The rule does not hear of that move: the committed close ends the tab's relations
    /// (``settle(_:lists:before:closing:)``), and a close that is cancelled or refused leaves them as they
    /// were, a quick look-up's too. Nothing is kept after `body` returns.
    public func closeSelects<T>(_ body: () -> T) -> T {
        let outer = inClosePick
        inClosePick = true
        defer { inClosePick = outer }
        return body()
    }

    /// `tab` was made in `pane` from `opener`, by a link or by an action inside `opener`, in the foreground
    /// or the background (a task opener). `quick`: a person's new tab put away from the current one.
    /// A foreground `quick` tab first forgets every relation of the pane.
    public func made(_ tab: String, from opener: String, in pane: String, quick: Bool = false, foreground: Bool) {
        let (item, parent) = (id(tab), id(opener))
        guard item != parent, foreground || !quick else { return }
        openers.made(item, opener: parent, kind: quick ? .quick : .task, foreground: foreground) { home[$0] == pane }
        guard openers.opener(of: item) != nil else { return }
        (home[item], home[parent]) = (pane, pane)
    }

    /// `pane` now selects `new`; it selected `old` before. `standIn`: the tab whose place `new` took.
    /// With no relation held and no new tab expected: three emptiness checks, nothing of the pane is read.
    func selected(_ new: String, after old: String?, in pane: String, standIn: String?) { // perf-hot: 10ms tab-switch
        let person = gesture.map { $0.pane == pane && $0.tab == new } ?? false
        if gesture?.pane == pane { gesture = nil }
        if closePick?.pane == pane { closePick = nil }
        guard !inClosePick, !home.isEmpty || !expected.isEmpty else { return }
        let from = old.map { id($0) }
        if let standIn { adopt(new, inPlaceOf: standIn) }
        let to = id(new)
        // A tab that took the selected tab's place is the same item: nothing moved.
        guard from != to else { return }
        if let made = expected.removeValue(forKey: pane), let from, from == id(made.opener), !made.listed.contains(new) {
            // The two modes of the decision: after the current tab = a task opener, not reported as foreground (the
            // pane's older relations stay); else the quick look-up. The move itself first: it ends a quick relation
            // of the tab the pane leaves.
            openers.selected(old: from, new: to, gesture: false) { home[$0] == pane }
            return self.made(to, from: from, in: pane, quick: made.quick, foreground: made.quick || made.link)
        }
        guard !home.isEmpty else { return }
        openers.selected(old: from, new: to, gesture: person) { home[$0] == pane }
        forgetWhenEmpty()
    }

    /// The tab a pane selects after `closed` left it: a tab it opened, a tab its opener opened, its
    /// opener, else the next shown tab, and the previous one only when it was the last. `old` is the
    /// pane's order before, `tabs` its tabs now, `hidden` the members of a collapsed group. Call it
    /// before ``settle(_:lists:before:closing:)`` for the tabs that left in this change.
    public func successor(of closed: String, old: [String], tabs: [String], hidden: Set<String> = []) -> String? {
        let shown = hidden.isEmpty ? Set(tabs) : Set(tabs).subtracting(hidden)
        guard !known.isEmpty else { return openers.successor(ofTab: closed, old: old, surviving: tabs, shown: shown) }
        let pick = openers.successor(ofTab: id(closed), old: old.map { id($0) }, surviving: tabs.map { id($0) }, shown: Set(shown.map { id($0) }))
        return pick.map { shownAs[$0] ?? $0 }
    }

    /// Same, for a strip's own ids (`TabStripModel.closeSuccessor`).
    public func successor(of closed: StripTabID, old: [StripTabID], surviving: [StripTabID], shown: Set<StripTabID>) -> StripTabID? {
        let tabs = surviving.map(\.rawValue)
        let hidden = Set(tabs).subtracting(shown.map(\.rawValue))
        return successor(of: closed.rawValue, old: old.map(\.rawValue), tabs: tabs, hidden: hidden).map { StripTabID($0) }
    }

    /// Tabs that took another tab's place in a pane (new to old, `TabStripModel.successors`): each keeps
    /// the relations of the tab it replaced. With no relation held it reads nothing.
    func adopt(_ replaced: [StripTabID: StripTabID]) {
        guard !home.isEmpty, !replaced.isEmpty else { return }
        for (new, old) in replaced { adopt(new.rawValue, inPlaceOf: old.rawValue) }
    }

    /// A typed navigation (the address bar; not a link click) in browser tab `tab` of `pane`: the person
    /// starts another task there, so every relation of the pane is forgotten, except at the first one in
    /// a quick look-up tab the person just made.
    public func typedNavigation(in tab: String, pane: String) {
        guard !home.isEmpty else { return }
        openers.typedNavigation(in: id(tab)) { home[$0] == pane }
        forgetWhenEmpty()
    }

    /// `pane` lists `tabs` now. A tab of the state that it no longer lists left its strip (its close is
    /// committed, or it moved to another pane), so its relations end: a relation holds inside one pane.
    /// A tab that a pending close only hides (`closing`: the store's close intents) stays: the press of a
    /// close keeps the relation, so a cancelled or refused close shows the tab again with its opener, and
    /// the committed close ends it. Call it after the pick; and before the pick with `old`, the pane's
    /// order before this change, so that a tab whose close was committed since the last call leaves first
    /// (the tabs it opened take its opener) while the tabs that leave in this change still count.
    /// `closing` is asked only when a tab of the state is not listed.
    func settle(_ pane: String, lists tabs: [String], before old: [String] = [], closing: () -> Set<String> = { [] }) {
        if !expected.isEmpty, let made = expected[pane], !tabs.contains(made.opener) { expected[pane] = nil }
        guard !home.isEmpty else { return }
        let held = home.filter { $0.value == pane }.map(\.key)
        guard !held.isEmpty else { return }
        let live = Set(tabs).union(old)
        let gone = held.filter { !live.contains(shownAs[$0] ?? $0) }
        if !gone.isEmpty {
            let pending = closing()
            for item in gone where !pending.contains(shownAs[item] ?? item) { left(item) }
        }
        forgetWhenEmpty()
    }

    /// Drops panes that no longer exist.
    func prune(livePanes: Set<String>) {
        if !expected.isEmpty { expected = expected.filter { livePanes.contains($0.key) } }
        guard !home.isEmpty else { return }
        for (item, pane) in home where !livePanes.contains(pane) { left(item) }
        forgetWhenEmpty()
    }

    /// The id the state knows `tab` by.
    private func id(_ tab: String) -> String { known.isEmpty ? tab : known[tab] ?? tab }

    /// `new` took `old`'s place: the state's item for `old` is shown as `new` from now on.
    private func adopt(_ new: String, inPlaceOf old: String) {
        let item = id(old)
        guard new != old, known[new] == nil, home[item] != nil else { return }
        if let before = shownAs[item] { known[before] = nil }
        (known[new], shownAs[item]) = (item, new)
    }

    private func left(_ item: String) {
        home[item] = nil
        if let shown = shownAs.removeValue(forKey: item) { known[shown] = nil }
        openers.left(item)
    }

    /// With no relation left, nothing of the state is kept: the numbers of the tabs go too.
    private func forgetWhenEmpty() {
        guard !home.isEmpty, openers.isEmpty else { return }
        for item in home.keys { openers.left(item) }
        home.removeAll()
        known.removeAll()
        shownAs.removeAll()
    }
}

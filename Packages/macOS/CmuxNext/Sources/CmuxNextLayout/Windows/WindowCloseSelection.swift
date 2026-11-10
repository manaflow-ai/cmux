import CmuxNextDesign

/// The close-selection rule's state for the workspaces of every window (plans/cmux-next/close-focus.md,
/// "One close-selection rule"; Lawrence 2026-11-10: "we need to copy how google chrome does it").
/// One instance, owned by the app's `WindowRegistryStore`. A window's workspaces are one strip.
///
/// A workspace a person makes in the foreground (Cmd-N, the plus button, the menu, the palette, a
/// row menu's New Workspace) keeps an opener: the workspace its window showed before. Closing it
/// returns there. Its lifetime follows the placement (decision 2026-11-10, Chrome 156 observed):
/// put after the current row (the default), the relation lasts as a link tab's does, until the
/// person selects an unrelated workspace; put at the end or the top, it is the quick look-up and
/// ends when the window's selection leaves the new workspace for any reason. A workspace made by
/// the CLI, the socket, MCP, a script, a restore, a move, a duplicate or a drag has no opener. A
/// relation never crosses windows.
///
/// Cost: with no relation held, `shown`, `left` and `settle` are each one or two emptiness checks
/// of a dictionary, and no call walks a window's members. With some held, `shown` and `left` ask
/// about the workspaces of those relations only; `settle` asks the registry for the window of each
/// (a few workspaces at most, on a membership change, never on a switch) and reads no row list.
public final class WindowCloseSelection {
    private let openers = CloseSelection<String>()
    /// A person's new workspaces their window does not show yet, each to that window.
    private var expected: [String: (window: String, quick: Bool)] = [:]
    /// The window of each workspace `openers` holds a number for.
    private var home: [String: String] = [:]
    /// A selection repair runs: the selection it sets is the close's, never a person's gesture.
    private var isRepairing = false
    /// The rule with no relation: the pick by position of a close of several rows (`pick(batch:)`).
    private lazy var byPosition = CloseSelection<String>()

    public init() {}

    /// No opener relation is held: every pick is by position.
    public var isEmpty: Bool { home.isEmpty }

    /// A person started `workspace` in the foreground of `window`. Call it before the window can
    /// show the workspace: it gets its opener when the window shows it (`shown`). `quick`: it is put
    /// away from the current row (at the end or the top), so the relation ends on any selection
    /// change. A create that failed, or that its window listed and did not show, ends in `settle`.
    public func expect(_ workspace: String, in window: String, quick: Bool) {
        expected[workspace] = (window, quick)
    }

    /// Makes `state` report each change of its shown workspace here: the one place every selection
    /// change of a window passes. `gesture`: the code running at the change is a person's own
    /// action (not the CLI, the socket, MCP or a script). With no relation held a report is two
    /// emptiness checks.
    @discardableResult
    public func watch<Window: CloseSelectionWindow>(_ state: Window, gesture: @escaping () -> Bool) -> Window {
        state.onShownChange = { [weak self, weak state] new, old in
            guard let self, let state else { return }
            shown(new, after: old, in: state.id, gesture: gesture())
        }
        return state
    }

    /// Runs a selection repair (the selection a close or a membership change causes). `isRepair` false:
    /// the repair selects a workspace the person just made or moved in, which is theirs.
    public func repairing<T>(_ isRepair: Bool = true, _ body: () -> T) -> T {
        let outer = isRepairing
        isRepairing = outer || isRepair
        defer { isRepairing = outer }
        return body()
    }

    /// `window` now shows `new`; it showed `old` before. `gesture`: a person chose `new`.
    public func shown(_ new: String?, after old: String?, in window: String, gesture: @autoclosure () -> Bool) {
        guard let new else { return }
        // The strip of a window: the workspaces of its live relations (`home`), never its members.
        let lists: (String) -> Bool = { self.home[$0] == window }
        if !expected.isEmpty, let made = expected.removeValue(forKey: new), made.window == window, let old {
            // The two modes of the decision: after the current row = a task opener, not reported as foreground
            // (the older relations of the window stay); else the quick look-up. The move itself first: it ends a
            // quick relation of the workspace the window leaves.
            openers.selected(old: old, new: new, gesture: false, among: lists)
            openers.made(new, opener: old, kind: made.quick ? .quick : .task, foreground: made.quick, among: lists)
            home[new] = window
            home[old] = window
            return
        }
        guard !home.isEmpty else { return }
        openers.selected(old: old, new: new, gesture: !isRepairing && gesture(), among: lists)
        forgetWhenEmpty()
    }

    /// `workspace` closed or left its window. Call it after the pick for the close.
    public func left(_ workspace: String) {
        if !expected.isEmpty { expected[workspace] = nil }
        guard home.removeValue(forKey: workspace) != nil else { return }
        openers.left(workspace)
        forgetWhenEmpty()
    }

    /// After the selection repair of `window`: a workspace of the state that no window lists any
    /// more (its close is committed: the daemon's delta took it from the registry), or that
    /// another window lists (moved), leaves the state, and so does one whose window is gone. A
    /// row that only left the window's rows (hidden at the press of a close that can still be
    /// cancelled or refused, or in another room) keeps its relation: the pick reads the
    /// surviving rows only, and a cancelled close shows the row again with its opener. `owner`:
    /// the window that lists a workspace now. `exists`: the window is registered. `claimed`: the
    /// workspace is a create its window waits for. With nothing held, none is asked.
    public func settle(_ window: String, owner: (String) -> String?, exists: (String) -> Bool, claimed: (String) -> Bool) {
        // A create the window lists and did not show in this repair is not in the foreground, and one
        // that is neither listed nor waited for failed, as did one whose window is gone: no opener.
        if !expected.isEmpty { expected = expected.filter { $0.value.window != window ? exists($0.value.window) : owner($0.key) == nil && claimed($0.key) } }
        guard !home.isEmpty else { return }
        for (workspace, at) in home {
            let gone = at != window ? !exists(at) : owner(workspace) != window && !claimed(workspace)
            if gone { left(workspace) }
        }
    }

    /// Window `old` took the identity `new` (the launch window adopts the frontmost saved window):
    /// its creates and relations follow it.
    public func renamed(window old: String, to new: String) {
        for (workspace, made) in expected where made.window == old { expected[workspace] = (new, made.quick) }
        for (workspace, at) in home where at == old { home[workspace] = new }
    }

    /// The workspace a window shows after `shown` left it: a workspace it opened, one its opener
    /// opened, its opener, else the next row below as drawn, and the row above only when it was
    /// the last. `previous` is the window's members before, `members` its members now, `orders`
    /// the sidebar's row orders before the close (the rows as drawn, then the model's). A row's
    /// group or section is not read (decision 2026-11-10, Chrome 156 as observed).
    ///
    /// `batch`: the person closed several rows in one gesture (a multi-selection, Close Others,
    /// Close Below, Close Above). Such a close keeps its own rule: the next row, else the previous
    /// one, with no opener rank.
    ///
    /// The rule (`cmux-focus-core` `successor_in_orders`) lets only the rows of the first order
    /// that lists `shown` be picked, and with no such order it picks the neighbor in `previous`
    /// with no opener rank. Two inputs are prepared here, only while a relation is held; Rust
    /// still decides whether the relation is live and what the pick is:
    /// - an opener of `shown` that is a member and that no order lists (a pinned layout tile,
    ///   drawn above the list) is put first in each order that lists `shown`. An opener that an
    ///   order lists but the drawn rows do not (a collapsed group, a filter) is not touched;
    /// - `previous` is the last order, so a workspace no row lists yet is picked over the members
    ///   with the opener rank. With no relation this is the same pick as the rule's own last step.
    /// The root place for both is the Rust function; a change there needs a new FFI release and
    /// pin (follow-up, with the tab PR), then this preparation goes.
    public func pick(shown: String?, previous: [String], members: [String], orders: [[String]] = [], batch: Bool = false) -> String? {
        if batch { return byPosition.workspace(shown: shown, old: previous, surviving: members, orders: orders) }
        guard !home.isEmpty, let shown else { return openers.workspace(shown: shown, old: previous, surviving: members, orders: orders) }
        var orders = orders
        if let opener = openers.opener(of: shown), members.contains(opener), !orders.contains(where: { $0.contains(opener) }) {
            for index in orders.indices where orders[index].contains(shown) { orders[index].insert(opener, at: 0) }
        }
        orders.append(previous)
        return openers.workspace(shown: shown, old: previous, surviving: members, orders: orders)
    }

    /// With no relation left, nothing of the state is kept: the numbers of the workspaces go too.
    private func forgetWhenEmpty() {
        guard !home.isEmpty, openers.isEmpty else { return }
        for workspace in home.keys { openers.left(workspace) }
        home.removeAll()
    }
}

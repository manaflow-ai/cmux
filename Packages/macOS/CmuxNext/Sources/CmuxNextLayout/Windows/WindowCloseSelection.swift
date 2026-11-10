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
/// about the workspaces of those relations only; `settle` looks each of them up in the window's
/// rows before and after (a few workspaces at most, on a membership change, never on a switch).
public final class WindowCloseSelection {
    private let openers = CloseSelection<String>()
    /// A person's new workspaces their window does not show yet, each to that window.
    private var expected: [String: (window: String, quick: Bool)] = [:]
    /// The window of each workspace `openers` holds a number for.
    private var home: [String: String] = [:]
    /// A selection repair runs: the selection it sets is the close's, never a person's gesture.
    private var isRepairing = false

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
            (home[new], home[old]) = (window, window)
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

    /// After the selection repair of `window`, whose rows went from `previous` to `members`: a
    /// workspace of the state that left those rows (closed), or that the window no longer lists
    /// (moved to another window), leaves the state, and so does one whose window is gone. `owner`:
    /// the window that lists a workspace now. `exists`: the window is registered. `claimed`: the
    /// workspace is a create its window waits for. With nothing held, none is asked.
    public func settle(_ window: String, previous: [String], members: [String], owner: (String) -> String?,
                       exists: (String) -> Bool, claimed: (String) -> Bool) {
        // A create the window lists and did not show in this repair is not in the foreground, and one
        // that is neither listed nor waited for failed, as did one whose window is gone: no opener.
        if !expected.isEmpty { expected = expected.filter { $0.value.window != window ? exists($0.value.window) : owner($0.key) == nil && claimed($0.key) } }
        guard !home.isEmpty else { return }
        for (workspace, at) in home {
            let gone = at != window ? !exists(at)
                : (owner(workspace) != window && !claimed(workspace)) || (previous.contains(workspace) && !members.contains(workspace))
            if gone { left(workspace) }
        }
    }

    /// The workspace a window shows after `shown` left it: a workspace it opened, one its opener
    /// opened, its opener, else the next row below as drawn, and the row above only when it was
    /// the last. `previous` is the window's members before, `members` its members now, `orders`
    /// the sidebar's row orders before the close (the rows as drawn, then the model's). A row's
    /// group or section is not read (decision 2026-11-10, Chrome 156 as observed).
    public func pick(shown: String?, previous: [String], members: [String], orders: [[String]] = []) -> String? {
        openers.workspace(shown: shown, old: previous, surviving: members, orders: orders)
    }

    /// With no relation left, nothing of the state is kept: the numbers of the workspaces go too.
    private func forgetWhenEmpty() {
        guard !home.isEmpty, openers.isEmpty else { return }
        for workspace in home.keys { openers.left(workspace) }
        home.removeAll()
    }
}

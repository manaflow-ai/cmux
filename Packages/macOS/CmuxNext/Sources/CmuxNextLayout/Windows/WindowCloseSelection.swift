import CCmuxLayoutReducerFFI

/// The close-selection rule's state for the workspaces of every window (plans/cmux-next/close-focus.md,
/// "One close-selection rule"; Lawrence 2026-11-10: "we need to copy how google chrome does it").
/// One instance, owned by the app's `WindowRegistryStore`. A window's workspaces are one strip.
///
/// The state and every decision are Rust's (cmux-focus-core `close_selection::windows::WindowCloseSelection`
/// behind `cmux_window_close_selection_*`): the creates a window waits to show, the window of each relation,
/// the selection repairs that run, the relations and the pick. This class owns the handle, numbers the app's
/// string ids for it and passes each fact on. Nothing here decides.
///
/// What Rust does with the facts: a workspace a person makes in the foreground (Cmd-N, the plus button, the
/// menu, the palette, a row menu's New Workspace) keeps an opener, the workspace its window showed before, and
/// closing it returns there. Put after the current row (the default), the relation lasts as a link tab's does,
/// until the person selects an unrelated workspace; put at the end or the top, it is the quick look-up and ends
/// when the window's selection leaves the new workspace. A workspace made by the CLI, the socket, MCP, a
/// script, a restore, a move, a duplicate or a drag has no opener. A relation never crosses windows.
///
/// Cost: while the state holds no id (`cmux_window_close_selection_holds_ids`), `shown`, `left`, `renamed`,
/// `settle` and a repair are one call that reads one flag: no id is numbered and nothing is allocated. With
/// some held, they number the ids of that call only, and a repair numbers the arrays it is given. A pick
/// numbers its arrays (one pass, as the pick did before); no call walks a window's members on a plain switch.
/// The numberings grow by each id reported while the state holds one, and go when it holds none.
public final class WindowCloseSelection {
    /// The relation a create starts (`CMUX_WINDOW_CLOSE_RELATION_*`). Each case maps to its constant by name:
    /// the codes are not `CloseSelection.Kind`'s raw values.
    public nonisolated enum Relation: Sendable {
        /// The create starts no relation.
        case none
        /// The quick look-up: ends when the window's selection leaves the new workspace.
        case quick
        /// Lasts as a link tab's relation: until the person selects an unrelated workspace.
        case task

        init(code: UInt8) {
            self = code == UInt8(CMUX_WINDOW_CLOSE_RELATION_QUICK) ? .quick : code == UInt8(CMUX_WINDOW_CLOSE_RELATION_TASK) ? .task : .none
        }

        var code: UInt8 {
            switch self {
            case .none: UInt8(CMUX_WINDOW_CLOSE_RELATION_NONE)
            case .quick: UInt8(CMUX_WINDOW_CLOSE_RELATION_QUICK)
            case .task: UInt8(CMUX_WINDOW_CLOSE_RELATION_TASK)
            }
        }
    }

    private let state = WindowCloseSelectionHandle()
    /// The app's ids as the state's two numberings. Dropped when the state holds no id.
    private var workspaces = CloseSelectionNumbers(), windows = CloseSelectionNumbers()
    /// The repairs of ``repair(shown:pick:gesture:pressed:members:preferred:_:)`` that run: inside one, the
    /// numberings stay (Rust holds the repair, so `cmux_window_close_selection_holds_ids` is nonzero there).
    private var repairs = 0

    public init() {}

    /// No opener relation is held: every pick is by position.
    public var isEmpty: Bool { cmux_window_close_selection_is_empty(state.pointer) != 0 }

    /// The relation a create into a window starts (`cmux_window_close_selection_relation`), from its facts: it
    /// opens the New Tab page, its run is the person's own action, the run may change the view, and the placement
    /// setting puts the new row after the current one.
    public nonisolated static func relation(opensNewTabPage: Bool, personsAction: Bool, mayChangeView: Bool, afterCurrent: Bool) -> Relation {
        Relation(code: cmux_window_close_selection_relation(opensNewTabPage ? 1 : 0, personsAction ? 1 : 0, mayChangeView ? 1 : 0, afterCurrent ? 1 : 0))
    }

    /// A create of `workspace` into `window` starts `relation` (``relation(opensNewTabPage:personsAction:mayChangeView:afterCurrent:)``;
    /// `.none` changes nothing). Call it before the window can show the workspace: it gets its opener when the
    /// window shows it (`shown`). A create that failed, or that its window listed and did not show, ends in `settle`.
    /// For `.none` no id is numbered: the call changes nothing (the header's contract).
    public func expect(_ workspace: String, in window: String, relation: Relation) {
        guard relation != .none else { return }
        cmux_window_close_selection_expect(state.pointer, workspaces.keep(workspace), windows.keep(window), relation.code)
        forgetWhenIdle()
    }

    /// Makes `state` report each change of its shown workspace here: the one place every selection change of a
    /// window passes. `gesture`: the code running at the change is a person's own action (not the CLI, the
    /// socket, MCP or a script). While the state holds no id a report reads one flag.
    @discardableResult
    public func watch<Window: CloseSelectionWindow>(_ state: Window, gesture: @escaping () -> Bool) -> Window {
        state.onShownChange = { [weak self, weak state] new, old in
            guard let self, let state else { return }
            shown(new, after: old, in: state.id, gesture: gesture())
        }
        return state
    }

    /// `window` now shows `new`; it showed `old` before. `gesture`: the code running at the change is a person's
    /// own action. Inside a repair the change is the close's, whatever `gesture` says. `gesture` is asked only
    /// while the state holds an id.
    public func shown(_ new: String?, after old: String?, in window: String, gesture: @autoclosure () -> Bool) {
        guard let new, cmux_window_close_selection_holds_ids(state.pointer) != 0 else { return }
        let before = old.map { workspaces.keep($0) } ?? CloseSelectionNumbers.none
        cmux_window_close_selection_shown(state.pointer, workspaces.keep(new), before, windows.keep(window), gesture() ? 1 : 0)
        forgetWhenIdle()
    }

    /// `workspace` closed or left its window. Call it after the pick for the close. One dictionary read for a
    /// workspace the state was never told of.
    public func left(_ workspace: String) {
        guard let number = workspaces.known(workspace) else { return }
        cmux_window_close_selection_left(state.pointer, number)
        workspaces.forget(workspace)
        forgetWhenIdle()
    }

    /// Window `old` took the identity `new` (the launch window adopts the frontmost saved window): its creates
    /// and relations follow it.
    public func renamed(window old: String, to new: String) {
        guard old != new, let from = windows.known(old) else { return }
        cmux_window_close_selection_renamed(state.pointer, from, windows.keep(new))
        windows.forget(old)
    }

    /// The workspace a window shows after `shown` left it (`cmux_window_close_selection_pick`): a workspace it
    /// opened, one its opener opened, its opener (also one that is a member and that no order lists), else the
    /// next row below as drawn, and the row above only when it was the last. `previous` is the window's members
    /// before, `members` its members now, `orders` the sidebar's row orders before the close, as they are (the
    /// rows as drawn, then the model's). A close of several rows in one gesture is this same call: `members`
    /// holds the survivors, so an opener that closes with it is no candidate. A `shown` that is a member stays.
    /// Call it before `left` for the closed workspaces.
    public func pick(shown: String?, previous: [String], members: [String], orders: [[String]] = []) -> String? {
        var ids = workspaces.call()
        let previous = previous.map { ids.number($0) }, members = members.map { ids.number($0) }
        let flat = orders.flatMap { order in order.map { ids.number($0) } }, lengths = orders.map { UInt32($0.count) }
        let shown = shown.map { ids.number($0) } ?? CloseSelectionNumbers.none
        let pick = previous.withUnsafeBufferPointer { previous in
            members.withUnsafeBufferPointer { members in
                flat.withUnsafeBufferPointer { flat in
                    lengths.withUnsafeBufferPointer { lengths in
                        var close = CmuxWindowClosePick(shown: shown, previous: previous.baseAddress, previous_count: previous.count,
                                                        members: members.baseAddress, member_count: members.count,
                                                        orders: flat.baseAddress, order_lengths: lengths.baseAddress, order_count: lengths.count)
                        return cmux_window_close_selection_pick(state.pointer, &close)
                    }
                }
            }
        }
        return ids.name(pick)
    }

    /// Runs one selection repair (`cmux_window_close_selection_repair_begin` and `_repair_end`): `body` selects
    /// `pick` in a window that showed `shown`, and the window reports that change through `shown`. Rust says
    /// whose selection it is: the close's, unless `gesture` (the caller says a person asked, in this turn, for
    /// the selection of a `preferred` workspace) and `pick` is one of `preferred`. `pressed`: the repair runs at
    /// the press of a close that hid rows and that can still be cancelled or refused (`InstantClose`); false
    /// for a daemon delta, a move, a room change and every other repair. `members`: the window's members now.
    public func repair<T>(shown: String?, pick: String?, gesture: Bool, pressed: Bool, members: [String], preferred: [String], _ body: () -> T) -> T {
        // With no id held (no create is waited for, no relation), a repair has nothing to keep or to end: one flag read, as `shown`.
        guard cmux_window_close_selection_holds_ids(state.pointer) != 0 else { return body() }
        // The two ids the state may keep first, then the arrays: an id only an array names takes a number for this call.
        let shown = shown.map { workspaces.keep($0) } ?? CloseSelectionNumbers.none, pick = pick.map { workspaces.keep($0) } ?? CloseSelectionNumbers.none
        var ids = workspaces.call()
        // Rust reads the members only at a press (did the press hide `shown`'s row?): any other repair numbers none.
        let members = pressed ? members.map { ids.number($0) } : [], preferred = preferred.map { ids.number($0) }
        members.withUnsafeBufferPointer { members in
            preferred.withUnsafeBufferPointer { preferred in
                var repair = CmuxWindowCloseRepair(shown: shown, pick: pick, gesture: gesture ? 1 : 0, pressed: pressed ? 1 : 0,
                                                   members: members.baseAddress, member_count: members.count,
                                                   preferred: preferred.baseAddress, preferred_count: preferred.count)
                cmux_window_close_selection_repair_begin(state.pointer, &repair)
            }
        }
        repairs += 1
        defer {
            cmux_window_close_selection_repair_end(state.pointer)
            repairs -= 1
            forgetWhenIdle()
        }
        return body()
    }

    /// Runs `body` as a repair with no pick of its own (`cmux_window_close_selection_repair_begin` with no
    /// repair struct): a selection `body` makes is a close's, never a person's gesture. For the selection a
    /// cancelled close makes when its row shows again: the relations stay as they were before the press, also
    /// when the pick of the press was by position (the opener closed in the same gesture).
    public func repairing<T>(_ body: () -> T) -> T {
        guard cmux_window_close_selection_holds_ids(state.pointer) != 0 else { return body() }
        cmux_window_close_selection_repair_begin(state.pointer, nil)
        repairs += 1
        defer {
            cmux_window_close_selection_repair_end(state.pointer)
            repairs -= 1
            forgetWhenIdle()
        }
        return body()
    }

    /// After the selection repair of `window` (`cmux_window_close_selection_settle_questions`, then `_settle`):
    /// Rust names the workspaces and the windows it holds, this answers with the registry's facts, and Rust
    /// ends the creates and relations of the workspaces that closed, moved, or whose window is gone. `owner`:
    /// the window that lists a workspace now. `exists`: the window is registered. `claimed`: the workspace is
    /// a create its window waits for. With nothing held, none is asked and no id is numbered.
    public func settle(_ window: String, owner: (String) -> String?, exists: (String) -> Bool, claimed: (String) -> Bool) {
        guard cmux_window_close_selection_holds_ids(state.pointer) != 0 else { return }
        let at = windows.keep(window)
        // A count above the arrays' size: one more question with arrays of that size (the state did not change between).
        var questions = settleQuestions(of: at, capacity: 8)
        if questions.needed > 8 { questions = settleQuestions(of: at, capacity: questions.needed) }
        let asked = questions.workspaces, others = questions.windows
        defer { forgetWhenIdle() }
        // Both empty: the settle is done.
        guard !(asked.isEmpty && others.isEmpty) else { return }
        let names = asked.map { workspaces.name($0) }
        let owners = names.map { name in name.flatMap(owner).map { windows.keep($0) } ?? CloseSelectionNumbers.none }
        let waits: [UInt8] = names.map { name in name.map(claimed) == true ? 1 : 0 }
        let registered: [UInt8] = others.map { windows.name($0).map(exists) == true ? 1 : 0 }
        asked.withUnsafeBufferPointer { asked in
            owners.withUnsafeBufferPointer { owners in
                waits.withUnsafeBufferPointer { waits in
                    others.withUnsafeBufferPointer { others in
                        registered.withUnsafeBufferPointer { registered in
                            var answers = CmuxWindowCloseSettle(window: at, workspaces: asked.baseAddress, owners: owners.baseAddress, claimed: waits.baseAddress,
                                                                workspace_count: asked.count, windows: others.baseAddress, exists: registered.baseAddress,
                                                                window_count: others.count)
                            cmux_window_close_selection_settle(state.pointer, &answers)
                        }
                    }
                }
            }
        }
    }

    /// One `cmux_window_close_selection_settle_questions` call with arrays of `capacity`: the workspaces and the
    /// windows Rust asks about (as many as fit), and the larger of the two counts it has.
    private func settleQuestions(of window: UInt32, capacity: Int) -> (workspaces: [UInt32], windows: [UInt32], needed: Int) {
        var workspaces = [UInt32](repeating: 0, count: capacity), windows = [UInt32](repeating: 0, count: capacity), windowCount = 0
        let count = workspaces.withUnsafeMutableBufferPointer { workspaces in
            windows.withUnsafeMutableBufferPointer { windows in
                cmux_window_close_selection_settle_questions(state.pointer, window, workspaces.baseAddress, windows.baseAddress, capacity, &windowCount)
            }
        }
        return (Array(workspaces.prefix(count)), Array(windows.prefix(windowCount)), max(count, windowCount))
    }

    /// While the state holds no id, the numberings go too. Never inside a repair.
    private func forgetWhenIdle() {
        guard repairs == 0, !(workspaces.isEmpty && windows.isEmpty), cmux_window_close_selection_holds_ids(state.pointer) == 0 else { return }
        workspaces.forgetAll()
        windows.forgetAll()
    }
}

/// Owns the `cmux_window_close_selection_*` handle: made one time, freed one time when the state lets go.
/// A null handle holds nothing: every pick is by position.
private nonisolated final class WindowCloseSelectionHandle {
    let pointer: OpaquePointer?

    init() {
        pointer = cmux_window_close_selection_new()
    }

    deinit {
        cmux_window_close_selection_free(pointer)
    }
}

/// The app's string ids as the `uint32_t` ids of one numbering of `cmux_window_close_selection_*`. An id the
/// state may keep gets a number that lasts (`keep`) until it leaves (`forget`) or the state holds no id
/// (`forgetAll`); an id only an array of one call names takes a number for that call (`call`). A number is
/// never used again, so one the state still holds names one id only.
private nonisolated struct CloseSelectionNumbers {
    /// `CMUX_FOCUS_NONE` (`UINT32_MAX`, which Swift does not import as a constant).
    static let none = UInt32.max

    private var numbers: [String: UInt32] = [:]
    private var names: [UInt32: String] = [:]
    /// The next unused number.
    private var next: UInt32 = 0

    var isEmpty: Bool { numbers.isEmpty }

    mutating func keep(_ id: String) -> UInt32 {
        if let known = numbers[id] { return known }
        let number = next
        next += 1
        numbers[id] = number
        names[number] = id
        return number
    }

    func known(_ id: String) -> UInt32? { numbers[id] }

    func name(_ number: UInt32) -> String? { names[number] }

    mutating func forget(_ id: String) {
        if let number = numbers.removeValue(forKey: id) { names[number] = nil }
    }

    mutating func forgetAll() {
        numbers.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
    }

    /// The numbers of one call: a kept id has its number, any other takes an unused one for this call only.
    /// Make it after the call's last `keep`.
    func call() -> Call { Call(kept: self, next: next) }

    nonisolated struct Call {
        let kept: CloseSelectionNumbers
        var next: UInt32
        private var extra: [String: UInt32] = [:]
        private var back: [UInt32: String] = [:]

        init(kept: CloseSelectionNumbers, next: UInt32) {
            self.kept = kept
            self.next = next
        }

        mutating func number(_ id: String) -> UInt32 {
            if let number = kept.numbers[id] ?? extra[id] { return number }
            let number = next
            next += 1
            extra[id] = number
            back[number] = id
            return number
        }

        func name(_ number: UInt32) -> String? { back[number] ?? kept.names[number] }
    }
}

import CCmuxLayoutReducerFFI

/// The one close-selection rule for tabs in a pane and workspaces in a window's sidebar
/// (plans/cmux-next/close-focus.md, "One close-selection rule"): who opened which item, and the
/// item selected after the selected one closed. The rule and its state are cmux-focus-core's
/// `close_selection::Openers` behind `cmux_close_selection_*`; nothing here decides. This owns the
/// handle and numbers the caller's ids for it.
///
/// A strip is one pane's tabs or one window's workspaces. One instance may hold the relations of
/// many strips: a call names its strip with `among` (true for an item of the strip). Only the
/// items of a live relation are asked, so a call costs O(live relations), never O(strip).
///
/// Numbers are persistent: an id gets one at its first `made` (as the new item or as the opener)
/// and keeps it until `left`. An id that was never in a `made` has no relation, so a call numbers
/// it for that call only. Not Sendable: its one owner uses it on one thread (in the app, the main
/// actor), and the handle is freed when that owner lets go. No call waits on a lock.
public nonisolated final class CloseSelection<ID: Hashable> {
    /// How long an opener relation lives (`CMUX_CLOSE_SELECTION_QUICK`, `CMUX_CLOSE_SELECTION_TASK`).
    public nonisolated enum Kind: UInt8, Sendable {
        /// A person made the item in the foreground: forgotten when the selection leaves the item.
        case quick = 0
        /// A link or an action inside the opener made it: kept until a deliberate selection of an
        /// unrelated item, or until one of the two leaves the strip.
        case task = 1
    }

    /// A null handle reads as no relation in every `cmux_close_selection_*` call (the pick is by position then).
    private let handle: OpaquePointer?

    private var numbers: [ID: UInt32] = [:]
    private var ids: [UInt32: ID] = [:]
    /// The next unused number. Never reused, so a number the state still holds names one id only.
    private var next: UInt32 = 0
    /// The items that may have a live opener: every relation's child is here.
    private var children: Set<ID> = []

    public init() {
        handle = cmux_close_selection_new()
    }

    deinit {
        cmux_close_selection_free(handle)
    }

    /// No opener relation is held (`cmux_close_selection_has_relations`): every pick is by position,
    /// and `selected` returns at once.
    public var isEmpty: Bool { cmux_close_selection_has_relations(handle) == 0 }

    /// `item` was made while `opener` was the selected item of its strip. `foreground`: the new
    /// item is selected; it first forgets every relation of the strip. A `quick` item that is not
    /// in the foreground gets no opener. Items made by automation, a restore, a move or a drag are
    /// not reported here.
    public func made(_ item: ID, opener: ID?, kind: Kind, foreground: Bool, among: (ID) -> Bool) {
        if kind == .quick, !foreground { return }
        let strip = strip(among)
        let child = number(item)
        let parent = opener.map { number($0) } ?? UInt32.max
        strip.withUnsafeBufferPointer {
            cmux_close_selection_made(handle, child, parent, kind.rawValue, foreground ? 1 : 0, $0.baseAddress, $0.count)
        }
        if opener != nil { children.insert(item) }
        prune()
    }

    /// The strip's selection moved from `old` to `new`. `gesture`: a person chose `new` (a click, a
    /// shortcut, the palette); a close and the selection it causes, and automation, are not one.
    /// With no relation held this returns before it asks `among` anything.
    public func selected(old: ID?, new: ID, gesture: Bool, among: (ID) -> Bool) {
        // First, and with no array built: while no relation is held the call changes nothing.
        guard cmux_close_selection_has_relations(handle) != 0, old != new else { return }
        let strip = strip(among)
        // An id with no number has no relation: an unused number names it for this call.
        let oldNumber = old.map { numbers[$0] ?? next } ?? UInt32.max
        let newNumber = numbers[new] ?? next + 1
        strip.withUnsafeBufferPointer {
            cmux_close_selection_selected(handle, oldNumber, newNumber, gesture ? 1 : 0, $0.baseAddress, $0.count)
        }
        prune()
    }

    /// A typed navigation (not a link click) in `tab`: it forgets every relation of the strip,
    /// except the first one in a tab the person just made.
    public func typedNavigation(in tab: ID, among: (ID) -> Bool) {
        guard let number = numbers[tab] else { return forgetAll(among: among) }
        let strip = strip(among)
        strip.withUnsafeBufferPointer { cmux_close_selection_typed_navigation(handle, number, $0.baseAddress, $0.count) }
        prune()
    }

    /// `item` left its strip (closed, or moved to another strip): the items it opened take its
    /// opener, and its number ends. Call it after the pick for the close. One dictionary read for
    /// an item that was never in a `made`.
    public func left(_ item: ID) {
        guard let number = numbers.removeValue(forKey: item) else { return }
        ids[number] = nil
        cmux_close_selection_left(handle, number)
        children.remove(item)
        prune()
    }

    /// Forgets every relation of the strip's items.
    public func forgetAll(among: (ID) -> Bool) {
        guard cmux_close_selection_has_relations(handle) != 0 else { return }
        let strip = strip(among)
        strip.withUnsafeBufferPointer { cmux_close_selection_forget_all(handle, $0.baseAddress, $0.count) }
        prune()
    }

    /// The live opener of `item`.
    public func opener(of item: ID) -> ID? {
        guard children.contains(item), let number = numbers[item] else { return nil }
        return ids[cmux_close_selection_opener(handle, number)]
    }

    /// The tab a pane selects after `selected` closed. `old` is the strip before the close,
    /// `surviving` the tabs left, `shown` the surviving tabs that are not hidden. No group map is
    /// passed (decision 2026-11-10, Chrome 156 as observed: the next tab, whatever its group).
    /// Call it before `left` for the closed tabs.
    public func tab(selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>) -> ID? {
        var map = CallNumbers(known: numbers, next: next)
        let selected = selected.map { map.number($0) } ?? UInt32.max
        let old = old.map { map.number($0) }
        let surviving = surviving.map { map.number($0) }
        let shown = shown.map { map.number($0) }
        let pick = old.withUnsafeBufferPointer { old in
            surviving.withUnsafeBufferPointer { surviving in
                shown.withUnsafeBufferPointer { shown in
                    cmux_close_selection_tab(handle, selected, old.baseAddress, old.count, surviving.baseAddress, surviving.count,
                                             shown.baseAddress, shown.count, nil, nil, 0)
                }
            }
        }
        return map.id(pick) ?? ids[pick]
    }

    /// The workspace a window shows after `shown` left it. `old` is the window's members before,
    /// `surviving` its members now, `orders` the sidebar's row orders before the close, most
    /// preferred first (the rows as drawn, then the model's rows). No group or section map is
    /// passed (decision 2026-11-10, Chrome 156 as observed): with no opener, the next row below,
    /// the row above only for the last row. A `shown` that survives stays. Call it before `left`
    /// for the closed workspaces.
    public func workspace(shown: ID?, old: [ID], surviving: [ID], orders: [[ID]] = []) -> ID? {
        var map = CallNumbers(known: numbers, next: next)
        let shown = shown.map { map.number($0) } ?? UInt32.max
        let old = old.map { map.number($0) }
        let surviving = surviving.map { map.number($0) }
        let flat = orders.flatMap { order in order.map { map.number($0) } }
        let lengths = orders.map { UInt32($0.count) }
        let pick = old.withUnsafeBufferPointer { old in
            surviving.withUnsafeBufferPointer { surviving in
                flat.withUnsafeBufferPointer { flat in
                    lengths.withUnsafeBufferPointer { lengths in
                        cmux_close_selection_workspace(handle, shown, old.baseAddress, old.count, surviving.baseAddress, surviving.count,
                                                       flat.baseAddress, lengths.baseAddress, lengths.count, nil, nil, 0)
                    }
                }
            }
        }
        return map.id(pick) ?? ids[pick]
    }

    /// The item a background child of `opener` goes after: the last of the run of `opener`'s
    /// descendants that directly follows it in `order`, else `opener`. A pinned item never ends the run.
    public func slot(opener: ID, order: [ID], pinned: Set<ID> = []) -> ID {
        var map = CallNumbers(known: numbers, next: next)
        let parent = map.number(opener)
        let order = order.map { map.number($0) }
        let pinned = pinned.map { map.number($0) }
        let pick = order.withUnsafeBufferPointer { order in
            pinned.withUnsafeBufferPointer { pinned in
                cmux_close_selection_slot(handle, parent, order.baseAddress, order.count, pinned.baseAddress, pinned.count)
            }
        }
        return map.id(pick) ?? ids[pick] ?? opener
    }

    private func number(_ id: ID) -> UInt32 {
        if let known = numbers[id] { return known }
        let number = next
        next += 1
        numbers[id] = number
        ids[number] = id
        return number
    }

    /// The strip's items that can matter to the state: each child `among` it, and its opener when
    /// that is `among` it too. No relation: no item, and `among` is not asked.
    private func strip(_ among: (ID) -> Bool) -> [UInt32] {
        var strip: [UInt32] = []
        for child in children where among(child) {
            guard let number = numbers[child] else { continue }
            strip.append(number)
            let opener = cmux_close_selection_opener(handle, number)
            if let parent = ids[opener], among(parent) { strip.append(opener) }
        }
        return strip
    }

    /// Drops the children whose relation ended in the state.
    private func prune() {
        guard !children.isEmpty else { return }
        children = children.filter { child in
            numbers[child].map { cmux_close_selection_opener(handle, $0) != UInt32.max } ?? false
        }
    }

    /// The ids of one pick: a known id keeps its persistent number, any other takes an unused one
    /// for this call only.
    private nonisolated struct CallNumbers {
        let known: [ID: UInt32]
        var next: UInt32
        private var extra: [ID: UInt32] = [:]
        private var back: [UInt32: ID] = [:]

        init(known: [ID: UInt32], next: UInt32) {
            self.known = known
            self.next = next
        }

        mutating func number(_ id: ID) -> UInt32 {
            if let number = known[id] ?? extra[id] { return number }
            let number = next
            next += 1
            extra[id] = number
            back[number] = id
            return number
        }

        func id(_ number: UInt32) -> ID? { back[number] }
    }
}

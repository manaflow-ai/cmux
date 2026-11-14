import CCmuxLayoutReducerFFI

/// The focus successor rules for every close kind (plans/cmux-next/close-focus.md), run by
/// cmux-focus-core (cmux-tui/crates/cmux-focus-core, `close_focus`) over the app FFI's typed
/// `cmux_close_focus_*` calls: one in-process call per close, no JSON. The focus reducer runs the
/// pane rule there too (a pane's tab pick is `CloseSelection.successor(ofTab:)`, a window's workspace pick `CloseSelection.workspace`). Nothing else decides a
/// successor, and no rule is in Swift: these number the caller's ids for the call and map the
/// answer back (the rules compare ids only by identity). The contract (C1-C4) and its model checks
/// are in the crate's tests (`tests/focus_rules`, closefocus.tla's cases).
public nonisolated enum FocusAfterClose {
    /// The opener relations among `order`, from `opener` (child to opener, possibly naming tabs
    /// that are gone). A tab whose opener is not in `order` takes that opener's own opener, as
    /// Chrome's `FixOpeners` does when a tab leaves the strip; a relation back to the tab itself is
    /// dropped. Only tabs in `order` are keys.
    public static func liveOpeners<ID: Hashable>(_ opener: [ID: ID], among order: [ID]) -> [ID: ID] {
        guard !opener.isEmpty, !order.isEmpty else { return [:] }
        var map = IDNumbering<ID>()
        let pairs = opener.map { ($0.key, $0.value) }
        let children = map.numbers(pairs.map(\.0))
        let parents = map.numbers(pairs.map(\.1))
        let tabs = map.numbers(order)
        var out = [UInt32](repeating: UInt32.max, count: tabs.count)
        let code = children.withUnsafeBufferPointer { children in
            parents.withUnsafeBufferPointer { parents in
                tabs.withUnsafeBufferPointer { tabs in
                    out.withUnsafeMutableBufferPointer { out in
                        cmux_close_focus_live_openers(children.baseAddress, parents.baseAddress, children.count,
                                                      tabs.baseAddress, tabs.count, out.baseAddress)
                    }
                }
            }
        }
        guard code == 0 else { return [:] }
        var result: [ID: ID] = [:]
        for (tab, parent) in zip(order, out) {
            if let parent = map.id(parent) { result[tab] = parent }
        }
        return result
    }
}

/// The caller's ids numbered for one `cmux_close_focus_*` call (`UInt32.max` is none).
private nonisolated struct IDNumbering<ID: Hashable> {
    private var ids: [ID] = []
    private var index: [ID: UInt32] = [:]

    mutating func number(_ id: ID) -> UInt32 {
        if let known = index[id] { return known }
        let next = UInt32(ids.count)
        ids.append(id)
        index[id] = next
        return next
    }

    mutating func numbers(_ list: some Sequence<ID>) -> [UInt32] { list.map { number($0) } }

    func id(_ number: UInt32) -> ID? {
        number == UInt32.max ? nil : ids.indices.contains(Int(number)) ? ids[Int(number)] : nil
    }

    mutating func optional(_ id: ID?) -> UInt32 { id.map { number($0) } ?? UInt32.max }
}

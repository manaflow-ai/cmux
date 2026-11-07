import CCmuxLayoutReducerFFI

/// The focus successor rules for every close kind (plans/cmux-next/close-focus.md), run by
/// cmux-focus-core (cmux-tui/crates/cmux-focus-core, `close_focus`) over the app FFI's typed
/// `cmux_close_focus_*` calls: one in-process call per close, no JSON. The focus reducer runs the
/// pane rule there too; tab selection and window selection call these. Nothing else decides a
/// successor, and no rule is in Swift: these number the caller's ids for the call and map the
/// answer back (the rules compare ids only by identity). The contract (C1-C4) and its model checks
/// are in the crate's tests (`tests/focus_rules`, closefocus.tla's cases).
public nonisolated enum FocusAfterClose {
    /// The tab a pane selects after `selected` closed: the next shown tab after it, else the
    /// previous shown one. `old` is the strip order before the close, `shown` the tabs that survive
    /// and are not hidden (a collapsed group's members are hidden). When no shown tab survives, the
    /// first surviving tab (its group then expands). `opener` maps a link tab to the tab that opened
    /// it (``liveOpeners(_:among:)``): a closed tab in that tree goes back to its family first, in
    /// Chrome's order (`DetermineNewSelectedIndex`): its next child, else a sibling, else its opener.
    public static func tab<ID: Hashable>(selected: ID?, old: [ID], surviving: [ID], shown: Set<ID>, opener: [ID: ID] = [:]) -> ID? {
        var map = IDNumbering<ID>()
        let selected = map.optional(selected)
        let old = map.numbers(old)
        let surviving = map.numbers(surviving)
        let shown = map.numbers(shown)
        let pairs = opener.map { ($0.key, $0.value) }
        let children = map.numbers(pairs.map(\.0))
        let parents = map.numbers(pairs.map(\.1))
        let pick = old.withUnsafeBufferPointer { old in
            surviving.withUnsafeBufferPointer { surviving in
                shown.withUnsafeBufferPointer { shown in
                    children.withUnsafeBufferPointer { children in
                        parents.withUnsafeBufferPointer { parents in
                            cmux_close_focus_tab(selected, old.baseAddress, old.count, surviving.baseAddress, surviving.count,
                                                 shown.baseAddress, shown.count, children.baseAddress, parents.baseAddress,
                                                 children.count)
                        }
                    }
                }
            }
        }
        return map.id(pick)
    }

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

    /// The workspace a window shows after `shown` left it: the next one below in the sidebar's
    /// visual order, else the one above. `old` is the order before, `surviving` the workspaces the
    /// window still lists, and `orders` the sidebar's row orders before the close, most preferred
    /// first (the rows as drawn, then the model's rows): the first that lists `shown` and has a
    /// surviving neighbor among `old` picks it. `old` decides last.
    public static func workspace<ID: Hashable>(shown: ID?, old: [ID], surviving: [ID], orders: [[ID]] = []) -> ID? {
        var map = IDNumbering<ID>()
        let shown = map.optional(shown)
        let old = map.numbers(old)
        let surviving = map.numbers(surviving)
        let flat = orders.flatMap { map.numbers($0) }
        let lengths = orders.map { UInt32($0.count) }
        let pick = old.withUnsafeBufferPointer { old in
            surviving.withUnsafeBufferPointer { surviving in
                flat.withUnsafeBufferPointer { flat in
                    lengths.withUnsafeBufferPointer { lengths in
                        cmux_close_focus_workspace(shown, old.baseAddress, old.count, surviving.baseAddress, surviving.count,
                                                   flat.baseAddress, lengths.baseAddress, lengths.count)
                    }
                }
            }
        }
        return map.id(pick)
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

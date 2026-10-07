import CoreGraphics

/// What a region drag moves: one item, or a section by its header.
nonisolated enum SidebarRegionDragSubject: Hashable, Sendable {
    case item(LayoutItemID)
    case section(LayoutSectionID)
}

/// The in-place reorder of the item sections (R77), the same model as the
/// workspace list: the region shows the shown sections with the move
/// already applied, and the drop sends one layout op for that order.
/// The rule is "take the place of what is under the pointer": over its own
/// (moved) slot nothing changes, so the order never flips back and forth.
nonisolated enum SidebarRegionReorder {
    /// `sections` with `subject` moved to the slot under `point` in
    /// `display` (the layout of `sections`), or nil when nothing moves.
    static func move(_ subject: SidebarRegionDragSubject, at point: CGPoint, display: SidebarRegionLayout,
                            sections: [LayoutSection]) -> [LayoutSection]? {
        switch subject {
        case let .item(id):
            return moveItem(id, at: point, display: display, sections: sections)
        case let .section(id):
            guard let s = sections.firstIndex(where: { $0.id == id }) else { return nil }
            let region = sections[s].region
            for t in sections.indices where t != s && sections[t].region == region {
                guard frame(of: sections[t].id, in: display)?.contains(point) == true else { continue }
                var out = sections
                let section = out.remove(at: s)
                out.insert(section, at: t)
                return out
            }
            return nil
        }
    }

    private static func moveItem(_ id: LayoutItemID, at point: CGPoint, display: SidebarRegionLayout,
                                 sections: [LayoutSection]) -> [LayoutSection]? {
        guard let (s, i) = SidebarLayoutReducer.locate(id, in: sections) else { return nil }
        let dragged = sections[s].items[i]
        func accepts(_ t: Int) -> Bool {
            sections[t].content == .items && (t == s || !sections[t].items.contains { $0.ref == dragged.ref })
        }
        var out = sections
        if let row = display.row(at: point), let (target, section) = item(of: row) {
            guard target != id, let t = sections.firstIndex(where: { $0.id == section }), accepts(t),
                  let ti = sections[t].items.firstIndex(where: { $0.id == target }) else { return nil }
            out[s].items.remove(at: i)
            out[t].items.insert(dragged, at: min(ti, out[t].items.count))
            return out
        }
        // The empty part of another section: the item goes last there.
        guard let t = sections.indices.first(where: { $0 != s && frame(of: sections[$0].id, in: display)?.contains(point) == true }),
              accepts(t) else { return nil }
        out[s].items.remove(at: i)
        out[t].items.append(dragged)
        return out
    }

    /// The layout op that gives the document the order of `shown` (the
    /// sections the region shows, hidden items left out): `subject` goes
    /// before the shown neighbor that follows it, or last.
    static func op(for subject: SidebarRegionDragSubject, shown: [LayoutSection], document: SidebarLayoutDocument) -> SidebarLayoutOp? {
        switch subject {
        case let .item(id):
            guard let (t, p) = SidebarLayoutReducer.locate(id, in: shown),
                  let target = document.sections.first(where: { $0.id == shown[t].id }) else { return nil }
            let rest = target.items.filter { $0.id != id }
            let next = shown[t].items.dropFirst(p + 1).lazy.compactMap { item in rest.firstIndex { $0.id == item.id } }.first
            return .itemMove(id, section: target.id, index: next ?? rest.count)
        case let .section(id):
            guard let p = shown.firstIndex(where: { $0.id == id }) else { return nil }
            let region = shown[p].region
            let rest = document.sections.filter { $0.region == region && $0.id != id }
            let next = shown.dropFirst(p + 1).lazy.filter { $0.region == region }
                .compactMap { section in rest.firstIndex { $0.id == section.id } }.first
            return .sectionMove(id, region: region, index: next ?? rest.count)
        }
    }

    /// The item a row shows, with its section.
    static func item(of row: SidebarRegionRow) -> (LayoutItemID, LayoutSectionID)? {
        switch row.kind {
        case let .item(id, section), let .tile(id, section), let .chip(id, section): (id, section)
        case .header, .app: nil
        }
    }

    /// The union of a section's rows (header, items, app content).
    static func frame(of section: LayoutSectionID, in layout: SidebarRegionLayout) -> CGRect? {
        layout.rows.reduce(nil as CGRect?) { frame, row in
            let owner: LayoutSectionID? = switch row.kind {
            case let .header(id), let .app(id): id
            case let .item(_, id), let .tile(_, id), let .chip(_, id): id
            }
            guard owner == section else { return frame }
            return frame.map { $0.union(row.frame) } ?? row.frame
        }
    }
}

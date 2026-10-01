import Foundation

/// Keyboard reorder (Cmd-Opt-Up/Down): moves the selected block one slot.
///
/// A slot is every place the block could be inserted, in visual order, inside
/// the block's current section. Moving down past an expanded group enters it
/// as the first child; moving up from a group's first child leaves it.
/// Collapsed groups are stepped over. The block never leaves its section, so
/// keyboard reorder never pins, unpins, or crosses machines by surprise.
public nonisolated enum KeyboardReorder {
    public enum Direction: Sendable {
        case up
        case down
    }

    public static func target(moving ids: [WorkspaceID], direction: Direction, in sections: [SidebarSection]) -> DropPosition? {
        let ordered = SidebarEdits.treeOrder(ids, in: sections)
        guard let first = ordered.first, let anchor = SidebarEdits.locate(first, in: sections) else { return nil }
        // Nothing precedes the anchor in tree order, so its indices already
        // are "after removal" coordinates.
        guard let current = SidebarEdits.position(of: first, in: sections) else { return nil }

        var remaining = sections
        _ = SidebarEdits.removeWorkspaces(Set(ordered), from: &remaining)
        let slots = slots(in: remaining[anchor.section])
        guard let i = slots.firstIndex(of: current) else { return nil }
        let j = direction == .up ? i - 1 : i + 1
        guard slots.indices.contains(j) else { return nil }
        return slots[j]
    }

    /// Every insertion slot in a section, in visual order.
    static func slots(in section: SidebarSection) -> [DropPosition] {
        var result: [DropPosition] = []
        for (index, node) in section.nodes.enumerated() {
            result.append(DropPosition(section: section.id, index: index))
            if case let .group(group) = node, !group.isCollapsed {
                for child in 0...group.workspaces.count {
                    result.append(DropPosition(section: section.id, group: group.id, index: child))
                }
            }
        }
        result.append(DropPosition(section: section.id, index: section.nodes.count))
        return result
    }
}

/// Case- and diacritic-insensitive filter: every whitespace-separated token
/// must appear in the title, subtitle or status.
public nonisolated enum SidebarFilter {
    public static func matches(_ query: String, in sections: [SidebarSection]) -> Set<WorkspaceID>? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
        guard !tokens.isEmpty else { return nil }
        var result = Set<WorkspaceID>()
        for ws in sections.flatMap(\.workspaces) {
            let haystack = normalize([ws.title, ws.subtitle ?? "", ws.status?.searchText ?? ""].joined(separator: " "))
            if tokens.allSatisfy({ haystack.contains($0) }) { result.insert(ws.id) }
        }
        return result
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

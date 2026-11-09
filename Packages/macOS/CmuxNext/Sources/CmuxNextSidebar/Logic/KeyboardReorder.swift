import Foundation

/// Keyboard reorder (Cmd-Opt-Up/Down): moves the selected block one slot.
///
/// A slot is every place the block could be inserted, in visual order, inside
/// the block's current section. Moving down past an expanded group enters it
/// as the first child; moving up from a group's first child leaves it.
/// Subgroups are entered the same way. Collapsed groups are stepped over. The block never leaves its section, so
/// keyboard reorder never pins, unpins, or crosses machines by surprise.
public nonisolated enum KeyboardReorder {
    public enum Direction: Sendable {
        case up
        case down
    }

    /// The slot one step `direction` from the block `ids` (the shared rule, `sidebar_edits` `keyboard_target`).
    public static func target(moving ids: [WorkspaceID], direction: Direction, in sections: [SidebarSection]) -> DropPosition? {
        var request = RustEditRequest("keyboard_target", sections: RustSidebarEdits(sections).sections)
        (request.ids, request.direction) = (ids.map(\.rawValue), direction == .up ? "up" : "down")
        return (RustSidebarClient.call("sidebar_edits", request, as: RustEditPosition?.self) ?? nil)?.swiftValue
    }
}

/// Case- and diacritic-insensitive filter: every whitespace-separated token
/// must appear in the title, folder line or status.
public nonisolated enum SidebarFilter {
    public static func matches(_ query: String, in sections: [SidebarSection]) -> Set<WorkspaceID>? {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
        guard !tokens.isEmpty else { return nil }
        var result = Set<WorkspaceID>()
        for ws in sections.flatMap(\.workspaces) {
            let haystack = normalize([ws.title, ws.folderLine ?? "", ws.status ?? ""].joined(separator: " "))
            if tokens.allSatisfy({ haystack.contains($0) }) { result.insert(ws.id) }
        }
        return result
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

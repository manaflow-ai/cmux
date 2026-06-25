/// One row of a fully-resolved button context menu: either a runnable
/// ``CmuxResolvedConfigMenuAction`` or a visual separator.
///
/// This is the resolved counterpart to ``CmuxConfigContextMenuItem`` (the
/// `cmux.json` wire-schema value). The resolved list is built when a button
/// placement is resolved and rendered directly by the menu surfaces; the
/// separator carries its own `id` so the list stays `Identifiable` for SwiftUI.
public enum CmuxResolvedConfigContextMenuItem: Identifiable, Sendable, Hashable {
    /// A runnable menu entry.
    case action(CmuxResolvedConfigMenuAction)
    /// A visual separator, identified by `id`.
    case separator(id: String)

    /// The entry's stable identifier (the action's id, or the separator's id).
    public var id: String {
        switch self {
        case .action(let action):
            return action.id
        case .separator(let id):
            return id
        }
    }
}

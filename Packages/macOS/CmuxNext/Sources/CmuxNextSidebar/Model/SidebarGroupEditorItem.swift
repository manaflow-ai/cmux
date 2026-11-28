import Foundation

/// One action row of the group editor, filled by the App from the action
/// registry (the editor never runs an action itself).
public nonisolated struct SidebarGroupEditorItem: Hashable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    /// The shortcut's display text, if the action has one.
    public var shortcut: String?

    public init(id: String, title: String, symbol: String? = nil, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
    }
}

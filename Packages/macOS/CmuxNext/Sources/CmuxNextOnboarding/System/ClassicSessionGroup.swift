public import Foundation

/// A sidebar group of a classic cmux window (`tabManager.workspaceGroups`).
///
/// Classic keeps no member list: each workspace names its group through
/// ``ClassicSessionWorkspace/groupID``, in the window's workspace order.
public nonisolated struct ClassicSessionGroup: Codable, Equatable, Sendable {
    /// Classic's group id (a UUID string); the migration ledger maps it to the next group.
    public let id: String
    public let name: String
    /// Whether its members were hidden under the header (`isCollapsed`).
    public let collapsed: Bool
    /// Whether the group was pinned (`isPinned`); a pinned group comes over even when empty.
    public let pinned: Bool
    /// Its color (`customColor`, `#RRGGBB`); nil for the default.
    public let color: String?
    /// Its SF Symbol name (`iconSymbol`); nil for none.
    public let icon: String?

    public init(id: String, name: String, collapsed: Bool = false, pinned: Bool = false, color: String? = nil, icon: String? = nil) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.pinned = pinned
        self.color = color
        self.icon = icon
    }
}

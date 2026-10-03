import Foundation

/// Stable identifier of a workspace. For daemon workspaces this is the
/// daemon's `ws_…` id, qualified by machine when ids can collide.
public nonisolated struct WorkspaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Stable identifier for a tab shown beneath a workspace row.
public nonisolated struct TabID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Stable identifier of a workspace group.
public nonisolated struct GroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// A fresh id for a group the user just created in the UI.
    public static func make() -> GroupID { GroupID("grp_" + UUID().uuidString.lowercased()) }
    public var description: String { rawValue }
}

/// Stable identifier of a machine (one cmux-tui daemon session).
public nonisolated struct MachineID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let local = MachineID("local")
    public var description: String { rawValue }
}

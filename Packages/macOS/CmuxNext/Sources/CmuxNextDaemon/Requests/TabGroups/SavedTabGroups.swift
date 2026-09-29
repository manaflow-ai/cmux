import Foundation

// Saved tab groups (`saved-tab-groups-v1`, Chrome "save group"). Saving
// links the live group to a session-wide record through
// `TabGroupSnapshot.savedID`; renames, recolors, and membership changes of
// the live group update the record.

/// Every saved record.
public struct ListSavedTabGroupsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var savedGroups: [SavedTabGroupSnapshot]
        enum CodingKeys: String, CodingKey { case savedGroups = "saved_groups" }
    }
    public static let command = "list-saved-tab-groups"
    public init() {}
}

/// Saves a live group. Result: `{group, saved}` (the record id).
public struct SaveTabGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var group: TabGroupID
        public var saved: SavedTabGroupID
    }
    public static let command = "save-tab-group"
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }
}

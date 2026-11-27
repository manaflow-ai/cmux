import Foundation

/// Deletes the saved record linked to a live group; the group stays.
public struct UnsaveTabGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var group: TabGroupID
        public var unsaved: Bool
    }
    public static let command = "unsave-tab-group"
    public static let requiredCapability: String? = DaemonCapability.savedTabGroups.rawValue
    /// The live group (not the saved record id).
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }
}

/// Deletes a saved record by id; a linked live group stays, unlinked.
public struct DeleteSavedTabGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var saved: SavedTabGroupID
        public var deleted: Bool
    }
    public static let command = "delete-saved-tab-group"
    public static let requiredCapability: String? = DaemonCapability.savedTabGroups.rawValue
    public var saved: SavedTabGroupID
    public init(saved: SavedTabGroupID) { self.saved = saved }
}

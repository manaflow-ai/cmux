import Foundation

/// Deletes the saved record linked to a live group; the group stays.
public struct UnsaveTabGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var group: TabGroupID
        public var unsaved: Bool
    }
    public static let command = "unsave-tab-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.savedTabGroups
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
    public static let requiredCapability: String? = DaemonCapabilities.shared.savedTabGroups
    public var saved: SavedTabGroupID
    public init(saved: SavedTabGroupID) { self.saved = saved }
}

/// Reopens a saved group into `pane`. A still-linked live group is returned
/// unchanged; otherwise running terminals reattach, others start in their
/// saved directory, and browsers reopen at their saved URL.
public struct ReopenSavedTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "reopen-saved-tab-group"
    public static let requiredCapability: String? = DaemonCapabilities.shared.savedTabGroups
    public var saved: SavedTabGroupID
    public var pane: PaneID
    public var transaction: ClientTransactionID?
    public init(saved: SavedTabGroupID, pane: PaneID, transaction: ClientTransactionID? = nil) {
        self.saved = saved
        self.pane = pane
        self.transaction = transaction
    }
}

@available(*, deprecated, renamed: "ReopenSavedTabGroupRequest")
public typealias OpenSavedTabGroupRequest = ReopenSavedTabGroupRequest

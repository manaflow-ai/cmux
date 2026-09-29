import Foundation

// Saved tab groups (Chrome "save group"). TODO(feat-cmux-next-daemon):
// proposed commands under `tab-groups-v1`; wire names are guesses.

/// Saves an open group as a session-wide record.
public struct SaveTabGroupRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var saved: SavedTabGroupSnapshot
    }
    public static let command = "save-tab-group"
    public var group: TabGroupID
    public init(group: TabGroupID) { self.group = group }
}

/// Opens (restores) a saved group into a pane.
public struct OpenSavedTabGroupRequest: DaemonRequest {
    public typealias Response = TabGroupResult
    public static let command = "open-saved-tab-group"
    public var saved: SavedTabGroupID
    public var pane: PaneID?
    public var index: Int?
    public var transaction: ClientTransactionID?
    public init(saved: SavedTabGroupID, pane: PaneID? = nil, index: Int? = nil, transaction: ClientTransactionID? = nil) {
        self.saved = saved
        self.pane = pane
        self.index = index
        self.transaction = transaction
    }
}

/// Deletes the saved record; an open copy of the group stays open.
public struct UnsaveTabGroupRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "unsave-tab-group"
    public var saved: SavedTabGroupID
    public init(saved: SavedTabGroupID) { self.saved = saved }
}

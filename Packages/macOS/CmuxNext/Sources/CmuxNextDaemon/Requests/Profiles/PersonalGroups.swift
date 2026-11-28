import Foundation

// Personal workspace groups and per-workspace organization (`profiles-v1`,
// home session only). Group JSON is the workspace group shape plus `profile`.

public struct PersonalGroupResult: Decodable, Sendable, Equatable {
    public var group: WorkspaceGroupSnapshot
    public var changed: Bool
}

import Foundation

public enum TreeEventMode: String, Sendable, Codable {
    case coarse, deltas
}

public struct ListWorkspacesRequest: DaemonRequest {
    public typealias Response = DaemonTree
    public static let command = "list-workspaces"
    public init() {}
}

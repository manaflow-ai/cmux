import Foundation

public enum TreeEventMode: String, Sendable, Codable {
    case coarse, deltas
}

public struct SubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "subscribe"
    public var treeEvents: TreeEventMode
    public var surface: SurfaceID?
    public init(treeEvents: TreeEventMode = .deltas, surface: SurfaceID? = nil) {
        self.treeEvents = treeEvents
        self.surface = surface
    }

    enum CodingKeys: String, CodingKey {
        case treeEvents = "tree_events", surface
    }
}

public struct ListWorkspacesRequest: DaemonRequest {
    public typealias Response = DaemonTree
    public static let commandName: DaemonCommandName = "list-workspaces"
    public init() {}
}

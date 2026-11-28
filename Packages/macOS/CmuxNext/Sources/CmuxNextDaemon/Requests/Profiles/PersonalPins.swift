import Foundation

public struct ChangedResponse: Decodable, Sendable, Equatable {
    public var changed: Bool
}

/// Pins a workspace to one room (Move Workspace to Room), replacing any pin.
public struct PinWorkspaceRequest: DaemonRequest {
    public typealias Response = ChangedResponse
    public static let command = "pin-workspace"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var workspaceKey: WorkspaceKey
    public var profile: ProfileID
    public init(sessionID: String, workspaceKey: WorkspaceKey, profile: ProfileID) {
        self.sessionID = sessionID
        self.workspaceKey = workspaceKey
        self.profile = profile
    }
}

public struct UnpinWorkspaceRequest: DaemonRequest {
    public typealias Response = ChangedResponse
    public static let command = "unpin-workspace"
    public static let requiredCapability: String? = DaemonCapabilities.shared.profiles
    public var sessionID: String
    public var workspaceKey: WorkspaceKey
    public init(sessionID: String, workspaceKey: WorkspaceKey) {
        self.sessionID = sessionID
        self.workspaceKey = workspaceKey
    }
}

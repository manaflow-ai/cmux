import Foundation

public struct CMUXSidebarSnapshot: Codable, Equatable, Sendable {
    public var apiVersion: CMUXExtensionAPIVersion
    public var sequence: UInt64
    public var windowID: UUID?
    public var selectedWorkspaceID: UUID?
    public var workspaces: [CMUXSidebarWorkspace]

    public init(
        apiVersion: CMUXExtensionAPIVersion = .sidebarV1,
        sequence: UInt64,
        windowID: UUID? = nil,
        selectedWorkspaceID: UUID?,
        workspaces: [CMUXSidebarWorkspace]
    ) {
        self.apiVersion = apiVersion
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }
}

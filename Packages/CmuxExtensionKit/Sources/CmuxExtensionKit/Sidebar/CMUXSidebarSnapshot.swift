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

    public func filtered(for scopes: some Sequence<CMUXExtensionScope>) -> CMUXSidebarSnapshot {
        let scopeSet = Set(scopes)
        guard scopeSet.contains(.workspaceMetadata) else {
            return CMUXSidebarSnapshot(
                apiVersion: apiVersion,
                sequence: sequence,
                selectedWorkspaceID: nil,
                workspaces: []
            )
        }
        return CMUXSidebarSnapshot(
            apiVersion: apiVersion,
            sequence: sequence,
            windowID: windowID,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces.map { $0.filtered(for: scopeSet) }
        )
    }
}

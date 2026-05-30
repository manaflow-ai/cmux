import Foundation

public struct CMUXSidebarSnapshot: Codable, Equatable, Sendable {
    public var apiVersion: CMUXExtensionAPIVersion
    public var sequence: UInt64
    public var windowID: UUID?
    public var selectedWorkspaceID: UUID?
    public var grantedReadScopes: Set<CMUXExtensionScope>
    public var grantedActionScopes: Set<CMUXExtensionActionScope>
    public var workspaces: [CMUXSidebarWorkspace]

    public init(
        apiVersion: CMUXExtensionAPIVersion = .sidebarV1,
        sequence: UInt64,
        windowID: UUID? = nil,
        selectedWorkspaceID: UUID?,
        grantedReadScopes: Set<CMUXExtensionScope> = [],
        grantedActionScopes: Set<CMUXExtensionActionScope> = [],
        workspaces: [CMUXSidebarWorkspace]
    ) {
        self.apiVersion = apiVersion
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.grantedReadScopes = grantedReadScopes
        self.grantedActionScopes = grantedActionScopes
        self.workspaces = workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(CMUXExtensionAPIVersion.self, forKey: .apiVersion)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        windowID = try container.decodeIfPresent(UUID.self, forKey: .windowID)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        grantedReadScopes = try container.decodeIfPresent(Set<CMUXExtensionScope>.self, forKey: .grantedReadScopes) ?? []
        grantedActionScopes = try container.decodeIfPresent(Set<CMUXExtensionActionScope>.self, forKey: .grantedActionScopes) ?? []
        workspaces = try container.decode([CMUXSidebarWorkspace].self, forKey: .workspaces)
    }

    public func filtered(
        for scopes: some Sequence<CMUXExtensionScope>,
        actionScopes: some Sequence<CMUXExtensionActionScope> = []
    ) -> CMUXSidebarSnapshot {
        let scopeSet = Set(scopes)
        let actionScopeSet = Set(actionScopes)
        guard scopeSet.contains(.workspaceList) || scopeSet.contains(.workspaceMetadata) else {
            return CMUXSidebarSnapshot(
                apiVersion: apiVersion,
                sequence: sequence,
                selectedWorkspaceID: nil,
                grantedReadScopes: scopeSet,
                grantedActionScopes: actionScopeSet,
                workspaces: []
            )
        }
        return CMUXSidebarSnapshot(
            apiVersion: apiVersion,
            sequence: sequence,
            windowID: windowID,
            selectedWorkspaceID: selectedWorkspaceID,
            grantedReadScopes: scopeSet,
            grantedActionScopes: actionScopeSet,
            workspaces: workspaces.map { workspace in
                scopeSet.contains(.workspaceMetadata)
                    ? workspace.filtered(for: scopeSet)
                    : CMUXSidebarWorkspace(id: workspace.id, title: workspace.title)
            }
        )
    }
}

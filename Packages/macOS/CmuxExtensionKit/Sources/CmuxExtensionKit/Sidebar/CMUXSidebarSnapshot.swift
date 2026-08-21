import Foundation

public struct CmuxSidebarSnapshot: Codable, Equatable, Sendable {
    public var apiVersion: CmuxExtensionAPIVersion
    public var sequence: UInt64
    public var windowID: UUID?
    public var selectedWorkspaceID: UUID?
    public var grantedReadScopes: Set<CmuxExtensionScope>
    public var grantedActionScopes: Set<CmuxExtensionActionScope>
    public var creationContexts: [CmuxSidebarCreationContext]
    public var selectedCreationContextID: String?
    public var workspaces: [CmuxSidebarWorkspace]

    /// The child-column route owned by the selected creation context.
    public var selectedChildColumn: CmuxSidebarChildColumn? {
        if let selectedCreationContextID,
           let selected = creationContexts.first(where: { $0.id == selectedCreationContextID })
        {
            return selected.childColumn
        }
        return creationContexts.first(where: \.isSelected)?.childColumn
    }

    public init(
        apiVersion: CmuxExtensionAPIVersion = .sidebarV2,
        sequence: UInt64,
        windowID: UUID? = nil,
        selectedWorkspaceID: UUID?,
        grantedReadScopes: Set<CmuxExtensionScope> = [],
        grantedActionScopes: Set<CmuxExtensionActionScope> = [],
        creationContexts: [CmuxSidebarCreationContext] = [],
        selectedCreationContextID: String? = nil,
        workspaces: [CmuxSidebarWorkspace]
    ) {
        self.apiVersion = apiVersion
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.grantedReadScopes = grantedReadScopes
        self.grantedActionScopes = grantedActionScopes
        self.creationContexts = creationContexts
        self.selectedCreationContextID = selectedCreationContextID
        self.workspaces = workspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(CmuxExtensionAPIVersion.self, forKey: .apiVersion)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        windowID = try container.decodeIfPresent(UUID.self, forKey: .windowID)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        grantedReadScopes = try container.decodeLossySetIfPresent(CmuxExtensionScope.self, forKey: .grantedReadScopes)
        grantedActionScopes = try container.decodeLossySetIfPresent(CmuxExtensionActionScope.self, forKey: .grantedActionScopes)
        creationContexts = try container.decodeIfPresent(
            [CmuxSidebarCreationContext].self,
            forKey: .creationContexts
        ) ?? []
        selectedCreationContextID = try container.decodeIfPresent(
            String.self,
            forKey: .selectedCreationContextID
        )
        workspaces = try container.decode([CmuxSidebarWorkspace].self, forKey: .workspaces)
    }

    @_spi(CmuxHostTransport)
    public func filtered(
        for scopes: some Sequence<CmuxExtensionScope>,
        actionScopes: some Sequence<CmuxExtensionActionScope> = []
    ) -> CmuxSidebarSnapshot {
        let scopeSet = Set(scopes)
        let actionScopeSet = Set(actionScopes)
        let canReadWorkspaces = scopeSet.contains(.workspaceList) || scopeSet.contains(.workspaceMetadata)
        let canReadCreationContexts = scopeSet.contains(.creationContexts)
        return CmuxSidebarSnapshot(
            apiVersion: apiVersion,
            sequence: sequence,
            windowID: scopeSet.contains(.workspaceMetadata) || canReadCreationContexts ? windowID : nil,
            selectedWorkspaceID: scopeSet.contains(.workspaceMetadata) ? selectedWorkspaceID : nil,
            grantedReadScopes: scopeSet,
            grantedActionScopes: actionScopeSet,
            creationContexts: canReadCreationContexts ? creationContexts.map { context in
                guard canReadWorkspaces else {
                    var redacted = context
                    redacted.workspaceIDs = []
                    return redacted
                }
                return context
            } : [],
            selectedCreationContextID: canReadCreationContexts ? selectedCreationContextID : nil,
            workspaces: canReadWorkspaces ? workspaces.map { workspace in
                scopeSet.contains(.workspaceMetadata)
                    ? workspace.filtered(for: scopeSet)
                    : CmuxSidebarWorkspace(id: workspace.id, title: "")
            } : []
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeLossySetIfPresent<Value>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Set<Value> where Value: RawRepresentable, Value.RawValue == String, Value: Hashable {
        guard let rawValues = try decodeIfPresent([String].self, forKey: key) else { return [] }
        return Set(rawValues.compactMap(type.init(rawValue:)))
    }
}

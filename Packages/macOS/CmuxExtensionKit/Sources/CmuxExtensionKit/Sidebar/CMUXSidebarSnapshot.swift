import Foundation

public struct CmuxSidebarSnapshot: Codable, Equatable, Sendable {
    public var apiVersion: CmuxExtensionAPIVersion
    public var sequence: UInt64
    /// Whether the host accepts pushed-snapshot acknowledgements; absent on legacy hosts.
    @_spi(CmuxHostTransport) public var supportsSnapshotAcknowledgement = false
    public var windowID: UUID?
    public var selectedWorkspaceID: UUID?
    /// Native sidebar multi-selection, in workspace order. Focus can be separate.
    public var selectedWorkspaceIDs: [UUID]
    public var selectionAnchorWorkspaceID: UUID?
    public var grantedReadScopes: Set<CmuxExtensionScope>
    public var grantedActionScopes: Set<CmuxExtensionActionScope>
    public var workspaces: [CmuxSidebarWorkspace]
    /// Authoritative native groups, shared only with the workspace-groups scope.
    public var workspaceGroups: [CmuxSidebarWorkspaceGroup]

    public init(
        apiVersion: CmuxExtensionAPIVersion = .sidebarV2_3,
        sequence: UInt64,
        windowID: UUID? = nil,
        selectedWorkspaceID: UUID?,
        selectedWorkspaceIDs: [UUID]? = nil,
        selectionAnchorWorkspaceID: UUID? = nil,
        grantedReadScopes: Set<CmuxExtensionScope> = [],
        grantedActionScopes: Set<CmuxExtensionActionScope> = [],
        workspaces: [CmuxSidebarWorkspace],
        workspaceGroups: [CmuxSidebarWorkspaceGroup] = []
    ) {
        self.apiVersion = apiVersion
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedWorkspaceIDs = selectedWorkspaceIDs ?? selectedWorkspaceID.map { [$0] } ?? []
        self.selectionAnchorWorkspaceID = selectionAnchorWorkspaceID
        self.grantedReadScopes = grantedReadScopes
        self.grantedActionScopes = grantedActionScopes
        self.workspaces = workspaces
        self.workspaceGroups = workspaceGroups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(CmuxExtensionAPIVersion.self, forKey: .apiVersion)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        supportsSnapshotAcknowledgement = try container.decodeIfPresent(Bool.self, forKey: .supportsSnapshotAcknowledgement) ?? false
        windowID = try container.decodeIfPresent(UUID.self, forKey: .windowID)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        selectedWorkspaceIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedWorkspaceIDs)
            ?? selectedWorkspaceID.map { [$0] } ?? []
        selectionAnchorWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectionAnchorWorkspaceID)
        grantedReadScopes = try container.decodeLossySetIfPresent(CmuxExtensionScope.self, forKey: .grantedReadScopes)
        grantedActionScopes = try container.decodeLossySetIfPresent(CmuxExtensionActionScope.self, forKey: .grantedActionScopes)
        workspaces = try container.decode([CmuxSidebarWorkspace].self, forKey: .workspaces)
        workspaceGroups = try container.decodeIfPresent([CmuxSidebarWorkspaceGroup].self, forKey: .workspaceGroups) ?? []
    }

    /// Negotiates acknowledgement only for a push from a host that supports it.
    /// - Parameter isPush: True for delivered snapshots, false for an initial refresh reply.
    /// - Returns: Whether the extension may call the optional acknowledgement method.
    @_spi(CmuxHostTransport) public func shouldAcknowledgeDelivery(isPush: Bool) -> Bool {
        isPush && supportsSnapshotAcknowledgement
    }

    @_spi(CmuxHostTransport)
    public func filtered(
        for scopes: some Sequence<CmuxExtensionScope>,
        actionScopes: some Sequence<CmuxExtensionActionScope> = []
    ) -> CmuxSidebarSnapshot {
        let scopeSet = Set(scopes)
        let actionScopeSet = Set(actionScopes)
        guard scopeSet.contains(.workspaceList) || scopeSet.contains(.workspaceMetadata) else {
            return CmuxSidebarSnapshot(
                apiVersion: apiVersion,
                sequence: sequence,
                selectedWorkspaceID: nil,
                grantedReadScopes: scopeSet,
                grantedActionScopes: actionScopeSet,
                workspaces: []
            )
        }
        return CmuxSidebarSnapshot(
            apiVersion: apiVersion,
            sequence: sequence,
            windowID: scopeSet.contains(.workspaceMetadata) ? windowID : nil,
            selectedWorkspaceID: scopeSet.contains(.workspaceMetadata) ? selectedWorkspaceID : nil,
            selectedWorkspaceIDs: scopeSet.contains(.workspaceMetadata) ? selectedWorkspaceIDs : [],
            selectionAnchorWorkspaceID: scopeSet.contains(.workspaceMetadata) ? selectionAnchorWorkspaceID : nil,
            grantedReadScopes: scopeSet,
            grantedActionScopes: actionScopeSet,
            workspaces: workspaces.map { workspace in
                scopeSet.contains(.workspaceMetadata)
                    ? workspace.filtered(for: scopeSet)
                    : CmuxSidebarWorkspace(id: workspace.id, title: "")
            },
            workspaceGroups: scopeSet.contains(.workspaceGroups) ? workspaceGroups : []
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

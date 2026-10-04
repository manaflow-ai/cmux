import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct SidebarManagementContractTests {
    private static let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let groupID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let neighborID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    @Test
    func nativeMetadataRoundTripsOverXPC() throws {
        let snapshot = Self.snapshot()
        let restored = try CmuxSidebarXPCCodec.decodeSnapshot(CmuxSidebarXPCCodec.encodeSnapshot(snapshot))
        #expect(restored == snapshot)
        #expect(restored.apiVersion == .sidebarV2_1)
        #expect(restored.workspaceGroups.first?.workspaceIDs == [Self.workspaceID])
        #expect(restored.workspaces.first?.surfaces.first?.runtime?.processGeneration == 7)
    }

    @Test(arguments: [false, true])
    func runtimeAndGroupDataRequireIndependentReadGrants(grantGroups: Bool) throws {
        let scopes: Set<CmuxExtensionScope> = grantGroups
            ? [.workspaceMetadata, .surfaceMetadata, .workspaceGroups]
            : [.workspaceMetadata, .surfaceMetadata, .agentRuntime]
        let filtered = Self.snapshot().filtered(for: scopes)
        let workspace = try #require(filtered.workspaces.first)
        let surface = try #require(workspace.surfaces.first)
        #expect(workspace.title == "Renamed workspace")
        #expect(workspace.importance == .followUp)
        #expect(workspace.isMuted)
        #expect(workspace.customColorHex == "#123456")
        #expect(workspace.groupID == (grantGroups ? Self.groupID : nil))
        #expect(filtered.workspaceGroups.isEmpty == !grantGroups)
        #expect((surface.runtime != nil) == !grantGroups)
        #expect(surface.workingDirectory == nil)
        #expect(workspace.latestNotification == nil)
    }

    @Test
    func groupOrRuntimeGrantAloneDoesNotExposeWorkspaceOrSurfaceMetadata() {
        let original = Self.snapshot()
        let noWorkspaceAccess = original.filtered(for: [.workspaceGroups, .agentRuntime])
        #expect(noWorkspaceAccess.workspaces.isEmpty)
        #expect(noWorkspaceAccess.workspaceGroups.isEmpty)
        let identityOnly = original.filtered(for: [.workspaceList, .agentRuntime])
        #expect(identityOnly.workspaces.count == 1)
        #expect(identityOnly.workspaces.first?.title == "")
        #expect(identityOnly.workspaces.first?.groupID == nil)
        #expect(identityOnly.workspaces.first?.importance == CmuxSidebarWorkspaceImportance.none)
        #expect(identityOnly.workspaces.first?.surfaces.isEmpty == true)
        let missingSurfaceGrant = original.filtered(for: [.workspaceMetadata, .agentRuntime])
        #expect(missingSurfaceGrant.workspaces.first?.surfaces.isEmpty == true)
    }

    @Test
    func legacySnapshotDoesNotInventGroupImportanceMuteOrRuntime() throws {
        let data = try JSONEncoder().encode(Self.snapshot())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["apiVersion"] = ["major": 2, "minor": 0]
        object.removeValue(forKey: "workspaceGroups")
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        for key in ["groupID", "importance", "isMuted", "customColorHex"] {
            workspaces[0].removeValue(forKey: key)
        }
        var surfaces = try #require(workspaces[0]["surfaces"] as? [[String: Any]])
        surfaces[0].removeValue(forKey: "runtime")
        workspaces[0]["surfaces"] = surfaces
        object["workspaces"] = workspaces
        let restored = try JSONDecoder().decode(
            CmuxSidebarSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(restored.apiVersion == .sidebarV2)
        #expect(restored.workspaceGroups.isEmpty)
        #expect(restored.workspaces.first?.groupID == nil)
        #expect(restored.workspaces.first?.importance == CmuxSidebarWorkspaceImportance.none)
        #expect(restored.workspaces.first?.isMuted == false)
        #expect(restored.workspaces.first?.customColorHex == nil)
        #expect(restored.workspaces.first?.surfaces.first?.runtime == nil)
        #expect(restored.workspaces.first?.title == "Renamed workspace")
    }

    @Test
    func unknownLifecycleRemainsUnknownInsteadOfIdle() throws {
        let lifecycle = try JSONDecoder().decode(CmuxSidebarAgentLifecycle.self, from: Data("\"future-state\"".utf8))
        let provenance = try JSONDecoder().decode(CmuxSidebarRuntimeProvenance.self, from: Data("\"future-source\"".utf8))
        let importance = try JSONDecoder().decode(CmuxSidebarWorkspaceImportance.self, from: Data("\"future-marker\"".utf8))
        #expect(lifecycle == .unknown)
        #expect(provenance == .unknown)
        #expect(importance == .none)
    }

    @Test
    func newManifestRequiresMatchingHostAndHonestScopeVersion() throws {
        let modern = CmuxExtensionManifest(
            id: "fr.yoyaku.cortex.sessions",
            displayName: "Cortex Sessions",
            readScopes: [.workspaceGroups, .agentRuntime],
            actionScopes: [.renameWorkspace, .deleteWorkspaceGroup, .closeWorkspace]
        )
        #expect(modern.minimumAPIVersion == .sidebarV2_1)
        try validateSidebarManifest(modern)
        #expect(throws: CmuxExtensionValidationError.unsupportedAPIVersion(requested: .sidebarV2_1, supported: .sidebarV2)) {
            try validateSidebarManifest(modern, supportedAPIVersion: .sidebarV2)
        }
        let legacy = CmuxExtensionManifest(
            id: "dev.example.legacy",
            displayName: "Legacy",
            actionScopes: [.selectWorkspace],
            minimumAPIVersion: .sidebarV2
        )
        try validateSidebarManifest(legacy, supportedAPIVersion: .sidebarV2)
        let dishonest = CmuxExtensionManifest(
            id: "dev.example.dishonest",
            displayName: "Dishonest",
            readScopes: [.agentRuntime],
            minimumAPIVersion: .sidebarV2
        )
        #expect(throws: CmuxExtensionValidationError.scopeRequiresAPIVersion(scope: "agentRuntime", required: .sidebarV2_1, declared: .sidebarV2)) {
            try validateSidebarManifest(dishonest)
        }
        let dishonestAction = CmuxExtensionManifest(
            id: "dev.example.dishonest",
            displayName: "Dishonest",
            actionScopes: [.renameSurface],
            minimumAPIVersion: .sidebarV2
        )
        #expect(throws: CmuxExtensionValidationError.scopeRequiresAPIVersion(scope: "renameSurface", required: .sidebarV2_1, declared: .sidebarV2)) {
            try validateSidebarManifest(dishonestAction)
        }
    }

    @Test
    func missingManifestVersionDefaultsToModernContractAndUnknownRequestedScopesFail() throws {
        let minimal = Data(#"{"id":"dev.example.sidebar","displayName":"Sidebar","readScopes":[]}"#.utf8)
        let manifest = try JSONDecoder().decode(CmuxExtensionManifest.self, from: minimal)
        #expect(manifest.minimumAPIVersion == .sidebarV2_1)
        let future = Data(#"{"id":"dev.example.sidebar","displayName":"Sidebar","readScopes":["futureScope"]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CmuxExtensionManifest.self, from: future)
        }
    }

    @Test
    func managementActionsRetainTargetsAndScopeRequirementsThroughXPC() throws {
        let actions: [(CmuxSidebarAction, Set<CmuxExtensionActionScope>)] = [
            (.renameWorkspace(workspaceID: Self.workspaceID, title: nil), [.renameWorkspace]),
            (.renameWorkspace(workspaceID: Self.workspaceID, title: ""), [.renameWorkspace]),
            (.renameSurface(workspaceID: Self.workspaceID, surfaceID: Self.surfaceID, title: "Named tab"), [.renameSurface]),
            (.renameWorkspaceGroup(groupID: Self.groupID, title: nil), [.renameWorkspaceGroup]),
            (.createWorkspaceGroup(name: "New group", workspaceIDs: [Self.workspaceID]), [.createWorkspaceGroup, .createWorkspace]),
            (.createWorkspaceGroup(name: "Empty group", workspaceIDs: []), [.createWorkspaceGroup, .createWorkspace]),
            (.setWorkspacePinned(workspaceID: Self.workspaceID, isPinned: true), [.pinWorkspace]),
            (.setWorkspaceImportance(workspaceID: Self.workspaceID, importance: .priority), [.setWorkspaceImportance]),
            (.setWorkspaceGroupCollapsed(groupID: Self.groupID, isCollapsed: true), [.collapseWorkspaceGroup]),
            (.moveWorkspaceToGroup(workspaceID: Self.workspaceID, groupID: Self.groupID), [.moveWorkspaceToGroup]),
            (.moveWorkspaceToGroup(workspaceID: Self.workspaceID, groupID: nil), [.moveWorkspaceToGroup]),
            (.ungroupWorkspaceGroup(groupID: Self.groupID), [.ungroupWorkspaceGroup]),
            (.deleteWorkspaceGroup(groupID: Self.groupID), [.deleteWorkspaceGroup, .closeWorkspace]),
            (.markWorkspaceRead(workspaceID: Self.workspaceID), [.manageNotifications]),
            (.markWorkspaceUnread(workspaceID: Self.workspaceID), [.manageNotifications]),
            (.clearWorkspaceNotifications(workspaceID: Self.workspaceID), [.manageNotifications]),
            (.setWorkspaceMuted(workspaceID: Self.workspaceID, isMuted: true), [.muteWorkspace]),
            (.setWorkspaceDescription(workspaceID: Self.workspaceID, description: "Follow up"), [.editWorkspaceDescription]),
            (.setWorkspaceColor(workspaceID: Self.workspaceID, colorHex: "#123456"), [.colorWorkspace]),
            (.moveWorkspace(workspaceID: Self.workspaceID, beforeWorkspaceID: Self.neighborID), [.reorderWorkspace]),
            (.moveWorkspace(workspaceID: Self.workspaceID, beforeWorkspaceID: nil), [.reorderWorkspace])
        ]
        for (action, scopes) in actions {
            let restored = try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action))
            #expect(restored == action)
            #expect(restored.requiredScopes == scopes)
        }
    }

    @Test
    @MainActor
    func deniedGroupCloseScopeDoesNotMasqueradeAsSuccess() async {
        let granted: Set<CmuxExtensionActionScope> = [.deleteWorkspaceGroup]
        let host = CmuxSidebarHost(performAction: { action, reply in
            reply(action.requiredScopes.isSubset(of: granted) ? .accepted : .rejected("Permission denied"))
        })
        do {
            try await host.deleteWorkspaceGroup(groupID: Self.groupID)
            Issue.record("Expected missing close permission to reject the request")
        } catch {
            #expect(error as? CmuxSidebarActionError == .rejected("Permission denied"))
        }
    }

    @Test
    @MainActor
    func groupCreationRequiresPermissionForItsNativeAnchor() async {
        let granted: Set<CmuxExtensionActionScope> = [.createWorkspaceGroup]
        let host = CmuxSidebarHost(performAction: { action, reply in
            reply(action.requiredScopes.isSubset(of: granted) ? .accepted : .rejected("Anchor creation denied"))
        })
        do {
            try await host.createWorkspaceGroup(name: "New group")
            Issue.record("Expected missing workspace creation permission to reject the request")
        } catch {
            #expect(error as? CmuxSidebarActionError == .rejected("Anchor creation denied"))
        }
    }

    @Test
    @MainActor
    func typedHelpersUseSharedReplyChannelAndPreserveExplicitTargets() async throws {
        var actions: [CmuxSidebarAction] = []
        let host = CmuxSidebarHost(performAction: { action, reply in
            actions.append(action)
            reply(.accepted)
        })
        try await host.renameWorkspace(workspaceID: Self.workspaceID)
        try await host.renameSurface(workspaceID: Self.workspaceID, surfaceID: Self.surfaceID, title: "Tab")
        try await host.renameWorkspaceGroup(groupID: Self.groupID)
        try await host.createWorkspaceGroup(name: "New group", workspaceIDs: [Self.workspaceID])
        try await host.setWorkspacePinned(workspaceID: Self.workspaceID, isPinned: true)
        try await host.setWorkspaceImportance(workspaceID: Self.workspaceID, importance: .followUp)
        try await host.setWorkspaceGroupCollapsed(groupID: Self.groupID, isCollapsed: true)
        try await host.moveWorkspaceToGroup(workspaceID: Self.workspaceID, groupID: Self.groupID)
        try await host.ungroupWorkspaceGroup(groupID: Self.groupID)
        try await host.deleteWorkspaceGroup(groupID: Self.groupID)
        try await host.markWorkspaceRead(workspaceID: Self.workspaceID)
        try await host.markWorkspaceUnread(workspaceID: Self.workspaceID)
        try await host.clearWorkspaceNotifications(workspaceID: Self.workspaceID)
        try await host.setWorkspaceMuted(workspaceID: Self.workspaceID, isMuted: true)
        try await host.setWorkspaceDescription(workspaceID: Self.workspaceID, description: nil)
        try await host.setWorkspaceColor(workspaceID: Self.workspaceID, colorHex: nil)
        try await host.moveWorkspace(workspaceID: Self.workspaceID, beforeWorkspaceID: nil)
        #expect(actions == [
            .renameWorkspace(workspaceID: Self.workspaceID, title: nil),
            .renameSurface(workspaceID: Self.workspaceID, surfaceID: Self.surfaceID, title: "Tab"),
            .renameWorkspaceGroup(groupID: Self.groupID, title: nil),
            .createWorkspaceGroup(name: "New group", workspaceIDs: [Self.workspaceID]),
            .setWorkspacePinned(workspaceID: Self.workspaceID, isPinned: true),
            .setWorkspaceImportance(workspaceID: Self.workspaceID, importance: .followUp),
            .setWorkspaceGroupCollapsed(groupID: Self.groupID, isCollapsed: true),
            .moveWorkspaceToGroup(workspaceID: Self.workspaceID, groupID: Self.groupID),
            .ungroupWorkspaceGroup(groupID: Self.groupID),
            .deleteWorkspaceGroup(groupID: Self.groupID),
            .markWorkspaceRead(workspaceID: Self.workspaceID),
            .markWorkspaceUnread(workspaceID: Self.workspaceID),
            .clearWorkspaceNotifications(workspaceID: Self.workspaceID),
            .setWorkspaceMuted(workspaceID: Self.workspaceID, isMuted: true),
            .setWorkspaceDescription(workspaceID: Self.workspaceID, description: nil),
            .setWorkspaceColor(workspaceID: Self.workspaceID, colorHex: nil),
            .moveWorkspace(workspaceID: Self.workspaceID, beforeWorkspaceID: nil)
        ])
    }

    private static func snapshot() -> CmuxSidebarSnapshot {
        let runtime = CmuxSidebarRuntimeObservation(
            lifecycle: .needsInput,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: .nativeLifecycle,
            sessionID: "session-123",
            toolID: "codex",
            processGeneration: 7
        )
        return CmuxSidebarSnapshot(
            sequence: 10,
            selectedWorkspaceID: workspaceID,
            workspaces: [CmuxSidebarWorkspace(
                id: workspaceID,
                title: "Renamed workspace",
                detail: "Native description",
                latestNotification: "Approval requested",
                surfaces: [CmuxSidebarSurface(id: surfaceID, title: "Renamed tab", workingDirectory: "/private", runtime: runtime)],
                groupID: groupID,
                importance: .followUp,
                isMuted: true,
                customColorHex: "#123456"
            )],
            workspaceGroups: [CmuxSidebarWorkspaceGroup(
                id: groupID,
                name: "Renamed group",
                isCollapsed: true,
                isPinned: true,
                anchorWorkspaceID: workspaceID,
                workspaceIDs: [workspaceID]
            )]
        )
    }
}

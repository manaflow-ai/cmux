import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct WorkspaceContextContractTests {
    @Test
    func scopedSnapshotRoundTripPreservesExactAnalysisMetadata() throws {
        let proposal = Self.proposal()
        let context = CmuxSidebarWorkspaceContext(revision: 12, tags: proposal.suggestedTags, aliases: ["Former name"], summary: "Accepted project purpose", rejectedAutomaticTagIDs: ["topic:obsolete"], analyzedProposal: proposal, canUndo: true)
        let workspace = CmuxSidebarWorkspace(id: UUID(), title: "Current name", context: context)
        let snapshot = CmuxSidebarSnapshot(sequence: 20, selectedWorkspaceID: workspace.id, workspaces: [workspace])
        let wire = try CmuxSidebarXPCCodec.decodeSnapshot(CmuxSidebarXPCCodec.encodeSnapshot(snapshot))
        #expect(wire.apiVersion == .sidebarV2_2)
        #expect(wire.workspaces.first?.context == context)
        #expect(wire.filtered(for: [.workspaceMetadata]).workspaces.first?.context == nil)
        #expect(wire.filtered(for: [.workspaceMetadata, .workspaceContext]).workspaces.first?.context == context)
        #expect(wire.filtered(for: [.workspaceContext]).workspaces.isEmpty)
        #expect(wire.filtered(for: [.workspaceList, .workspaceContext]).workspaces.first?.context == nil)
        #expect(wire.workspaces.first?.context?.analyzedProposal?.conversationIDs == ["Exact-Codex-ID", "Exact-Claude-ID"])
    }

    @Test
    func oldSnapshotsDecodeWithoutInventingContext() throws {
        let workspace = CmuxSidebarWorkspace(id: UUID(), title: "Legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        object.removeValue(forKey: "context")
        let decoded = try JSONDecoder().decode(CmuxSidebarWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.context == nil)
    }

    @Test
    func proposalRejectionsRoundTripAndOlderContextStartsWithoutThem() throws {
        let context = CmuxSidebarWorkspaceContext(rejectedSourceFingerprints: ["sha256:rejected"])
        #expect(try JSONDecoder().decode(CmuxSidebarWorkspaceContext.self, from: JSONEncoder().encode(context)) == context)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        object.removeValue(forKey: "rejectedSourceFingerprints")
        let legacy = try JSONDecoder().decode(CmuxSidebarWorkspaceContext.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.rejectedSourceFingerprints.isEmpty)
        let id = UUID()
        for mutation in [CmuxSidebarWorkspaceContextMutation.rejectProposal(id: id), .clearProposalRejections(fingerprints: ["sha256:rejected"]), .clearProposalRejections(fingerprints: nil)] {
            let action = CmuxSidebarAction.mutateWorkspaceContext(workspaceID: id, expectedRevision: 7, mutation: mutation)
            #expect(try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action)) == action)
            #expect(action.requiredScopes == [.editWorkspaceContext])
        }
    }

    @Test
    func contextActionsKeepIdentityRevisionAndIndependentRenamePermission() throws {
        let id = UUID()
        let proposal = Self.proposal()
        let actions: [(CmuxSidebarAction, Set<CmuxExtensionActionScope>)] = [
            (.mutateWorkspaceContext(workspaceID: id, expectedRevision: 8, mutation: .setManualTag(proposal.suggestedTags[0])), [.editWorkspaceContext]),
            (.mutateWorkspaceContext(workspaceID: id, expectedRevision: 8, mutation: .clearAutomaticTagRejections(ids: nil)), [.editWorkspaceContext]),
            (.storeWorkspaceContextProposal(workspaceID: id, expectedRevision: 8, proposal: proposal), [.editWorkspaceContext]),
            (.applyWorkspaceContextProposal(workspaceID: id, expectedRevision: 9, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: false, acceptSummary: true), [.editWorkspaceContext]),
            (.applyWorkspaceContextProposal(workspaceID: id, expectedRevision: 9, proposalID: proposal.id, tagIDs: [], acceptTitle: true, acceptSummary: false), [.editWorkspaceContext, .renameWorkspace]),
            (.undoWorkspaceContext(workspaceID: id, expectedRevision: 10), [.editWorkspaceContext, .renameWorkspace])
        ]
        for (action, scopes) in actions {
            let decoded = try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action))
            #expect(decoded == action)
            #expect(decoded.requiredScopes == scopes)
        }
    }

    @Test
    func contextManifestRequiresAPITwoPointTwo() throws {
        let manifest = CmuxExtensionManifest(id: "dev.example.context", displayName: "Context", readScopes: [.workspaceMetadata, .workspaceContext], actionScopes: [.editWorkspaceContext])
        try validateSidebarManifest(manifest)
        #expect(throws: CmuxExtensionValidationError.unsupportedAPIVersion(requested: .sidebarV2_2, supported: .sidebarV2_1)) {
            try validateSidebarManifest(manifest, supportedAPIVersion: .sidebarV2_1)
        }
        let dishonest = CmuxExtensionManifest(id: "dev.example.context", displayName: "Context", readScopes: [.workspaceContext], minimumAPIVersion: .sidebarV2_1)
        #expect(throws: CmuxExtensionValidationError.scopeRequiresAPIVersion(scope: "workspaceContext", required: .sidebarV2_2, declared: .sidebarV2_1)) {
            try validateSidebarManifest(dishonest)
        }
        let legacy = CmuxExtensionManifest(id: "dev.example.legacy", displayName: "Legacy", readScopes: [.workspaceMetadata], actionScopes: [.renameWorkspace], minimumAPIVersion: .sidebarV2_1)
        try validateSidebarManifest(legacy)
    }

    @Test
    @MainActor
    func asyncHelpersKeepNativeConflictStructured() async throws {
        let id = UUID()
        var received: [CmuxSidebarAction] = []
        let host = CmuxSidebarHost(performAction: { action, reply in
            received.append(action)
            reply(.rejected("Refresh required", reason: .revisionConflict))
        })
        do {
            try await host.mutateWorkspaceContext(workspaceID: id, expectedRevision: 5, mutation: .setSummary("New summary"))
            Issue.record("A stale revision must not appear successful")
        } catch {
            #expect(error as? CmuxSidebarActionError == .revisionConflict("Refresh required"))
        }
        #expect(received == [.mutateWorkspaceContext(workspaceID: id, expectedRevision: 5, mutation: .setSummary("New summary"))])
        let wire = try CmuxSidebarXPCCodec.decodeActionResult(CmuxSidebarXPCCodec.encodeActionResult(.rejected("Refresh required", reason: .revisionConflict)))
        #expect(wire.rejectionReason == .revisionConflict)
    }

    @Test
    @MainActor
    func asyncProposalAndUndoHelpersUseTheExistingReplyChannel() async throws {
        let id = UUID()
        let proposal = Self.proposal()
        var received: [CmuxSidebarAction] = []
        let host = CmuxSidebarHost(performAction: { action, reply in received.append(action); reply(.accepted) })
        try await host.storeWorkspaceContextProposal(workspaceID: id, expectedRevision: 0, proposal: proposal)
        try await host.applyWorkspaceContextProposal(workspaceID: id, expectedRevision: 1, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptSummary: true)
        try await host.undoWorkspaceContext(workspaceID: id, expectedRevision: 2)
        #expect(received == [
            .storeWorkspaceContextProposal(workspaceID: id, expectedRevision: 0, proposal: proposal),
            .applyWorkspaceContextProposal(workspaceID: id, expectedRevision: 1, proposalID: proposal.id, tagIDs: ["topic:printing"], acceptTitle: false, acceptSummary: true),
            .undoWorkspaceContext(workspaceID: id, expectedRevision: 2)
        ])
    }

    private static func proposal() -> CmuxSidebarWorkspaceContextProposal {
        CmuxSidebarWorkspaceContextProposal(suggestedTags: [CmuxSidebarContextTag(id: "topic:printing", label: "Printing", dimension: "topic", origin: .automatic, source: "analyzer")], suggestedTitle: "Print project", summary: "Prepare print runs", source: "analyzer", sourceFingerprint: "sha256:exact-source", conversationIDs: ["Exact-Codex-ID", "Exact-Claude-ID"], analyzedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

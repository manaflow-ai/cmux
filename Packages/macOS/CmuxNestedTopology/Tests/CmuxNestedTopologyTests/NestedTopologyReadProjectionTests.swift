import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite("NestedTopologyReadProjection")
struct NestedTopologyReadProjectionTests {
    @Test func publicCapabilityTokensAreStable() {
        #expect(NestedTopologyPublicCapability.readV1.rawValue == "nested_topology.read.v1")
        #expect(NestedTopologyPublicCapability.focusV1.rawValue == "nested_topology.focus.v1")
    }

    @Test func listProjectsCompoundIDsParentMapAndFocus() throws {
        var service = NestedTopologyReadService()
        let snapshot = NestedTopologyFixtures.snapshot()
        let attachment = NestedAttachmentRecord(
            attachmentID: NestedTopologyFixtures.attachmentID,
            hostWorkspaceID: "workspace:1",
            hostStableSurfaceID: NestedTopologyFixtures.hostSurfaceID,
            providerKind: .herdr,
            providerInstanceID: NestedTopologyFixtures.instanceA,
            capabilities: NestedCapabilitySet(capabilities: [.topologySnapshotV1, .topologyEventsV1]),
            state: .live,
            latestSnapshot: snapshot
        )

        let result = service.list(attachments: [attachment])
        #expect(result.capabilities == [.focusV1, .readV1])
        #expect(result.attachments.count == 1)

        let projected = result.attachments[0]
        #expect(projected.hostStableSurfaceID == NestedTopologyFixtures.hostSurfaceID)
        #expect(projected.state == .live)
        #expect(projected.nodes.count == 4)

        let workspace = try #require(projected.nodes.first { $0.id.kind == .workspace })
        let tab = try #require(projected.nodes.first { $0.id.kind == .tab })
        let pane = try #require(projected.nodes.first { $0.id.kind == .pane })
        let agent = try #require(projected.nodes.first { $0.id.kind == .agent })

        #expect(workspace.parentID == nil)
        #expect(tab.parentID == workspace.id)
        #expect(pane.parentID == tab.id)
        #expect(agent.parentID == pane.id)

        #expect(workspace.focused)
        #expect(tab.focused)
        #expect(pane.focused)
        #expect(agent.focused)
        #expect(pane.agent?.status == .idle)
        #expect(agent.accessibilityLabel.contains("idle"))
    }

    @Test func defaultOrderingIsDeterministicAcrossShuffledInputs() {
        let tree = NestedTopologyFixtures.baseTree()
        let w2 = NestedWorkspaceNode(
            id: NestedTopologyFixtures.nodeID(kind: .workspace, rawID: "w2"),
            displayTitle: "W2",
            orderIndex: 1
        )
        let t2 = NestedTabNode(
            id: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w2:t1"),
            workspaceID: w2.id,
            displayTitle: "T2",
            orderIndex: 0
        )

        let forward = NestedTopologyFixtures.snapshot(
            workspaces: [tree.workspace, w2],
            tabs: [tree.tab, t2],
            panes: [tree.pane],
            agents: [tree.agent],
            focus: NestedFocus(workspaceID: tree.workspace.id)
        )
        let reversed = NestedTopologyFixtures.snapshot(
            workspaces: [w2, tree.workspace],
            tabs: [t2, tree.tab],
            panes: [tree.pane],
            agents: [tree.agent],
            focus: NestedFocus(workspaceID: tree.workspace.id)
        )

        var serviceA = NestedTopologyReadService()
        var serviceB = NestedTopologyReadService()
        let attachmentA = liveAttachment(snapshot: forward)
        let attachmentB = liveAttachment(snapshot: reversed)

        let labelsA = serviceA.list(attachments: [attachmentA]).attachments[0].nodes.map(\.id.rawID)
        let labelsB = serviceB.list(attachments: [attachmentB]).attachments[0].nodes.map(\.id.rawID)
        #expect(labelsA == labelsB)
        #expect(labelsA.first == "w1")
    }

    @Test func staleStateIsVisibleOnNodes() {
        var service = NestedTopologyReadService()
        let attachment = NestedAttachmentRecord(
            attachmentID: NestedTopologyFixtures.attachmentID,
            hostWorkspaceID: "workspace:1",
            hostStableSurfaceID: NestedTopologyFixtures.hostSurfaceID,
            providerKind: .herdr,
            providerInstanceID: NestedTopologyFixtures.instanceA,
            state: .stale,
            latestSnapshot: NestedTopologyFixtures.snapshot()
        )
        let nodes = service.list(attachments: [attachment]).attachments[0].nodes
        #expect(nodes.allSatisfy { $0.stale })
        #expect(nodes.allSatisfy { $0.connectionState == .stale })
    }

    @Test func titleLockSuppressesOverwriteAndDiffSkipsThrash() throws {
        var renderer = NestedTopologyTwoPassRenderer()
        let snapshot = NestedTopologyFixtures.snapshot()
        let attachment = liveAttachment(snapshot: snapshot)
        let key = NestedAssociationKey(
            nodeID: snapshot.panes[0].id,
            sessionRawID: snapshot.panes[0].id.rawID,
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        renderer.lockTitle(for: key, title: "Locked Pane", authority: .user)

        let first = renderer.project(attachment: attachment)
        let paneLabel = try #require(first.nodes.first { $0.id.kind == .pane }?.label)
        #expect(paneLabel == "Locked Pane")

        var echoed = snapshot.panes[0]
        echoed.displayTitle = "Provider Echo"
        let echoedSnapshot = NestedTopologySnapshot(
            attachmentID: snapshot.attachmentID,
            hostStableSurfaceID: snapshot.hostStableSurfaceID,
            provider: snapshot.provider,
            workspaces: snapshot.workspaces,
            tabs: snapshot.tabs,
            panes: [echoed],
            agents: snapshot.agents,
            focus: snapshot.focus
        )
        let second = renderer.project(attachment: liveAttachment(snapshot: echoedSnapshot))
        let secondLabel = try #require(second.nodes.first { $0.id.kind == .pane }?.label)
        #expect(secondLabel == "Locked Pane")

        // Same locked value again must not thrash (identity-stable label).
        let third = renderer.project(attachment: liveAttachment(snapshot: echoedSnapshot))
        let thirdLabel = try #require(third.nodes.first { $0.id.kind == .pane }?.label)
        #expect(thirdLabel == secondLabel)
    }

    @Test func parentMapStableAcrossReshuffledEventBatches() {
        var renderer = NestedTopologyTwoPassRenderer()
        let tree = NestedTopologyFixtures.baseTree()
        let movedPane = NestedPaneNode(
            id: tree.pane.id,
            tabID: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t2"),
            displayTitle: "Pane 1",
            orderIndex: 0
        )
        let tab2 = NestedTabNode(
            id: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t2"),
            workspaceID: tree.workspace.id,
            displayTitle: "Tab 2",
            orderIndex: 1
        )

        let batchA: [NestedTopologyEvent] = [
            .tabUpserted(tab2),
            .paneUpserted(movedPane),
        ]
        let batchB: [NestedTopologyEvent] = [
            .paneUpserted(movedPane),
            .tabUpserted(tab2),
        ]

        var mapA = NestedParentMap()
        mapA.replace(with: NestedTopologyFixtures.snapshot())
        mapA.apply(events: batchA)

        var mapB = NestedParentMap()
        mapB.replace(with: NestedTopologyFixtures.snapshot())
        mapB.apply(events: batchB)

        #expect(mapA.parent(of: tree.pane.id) == tab2.id)
        #expect(mapA.sortedEdges.map { "\($0.child.rawID)->\($0.parent.rawID)" }
            == mapB.sortedEdges.map { "\($0.child.rawID)->\($0.parent.rawID)" })

        let attachmentID = NestedTopologyFixtures.hostSurfaceID
        renderer.applyParentMapEvents(batchA, attachmentID: attachmentID)
        #expect(renderer.parentMap.parent(of: tree.pane.id) == tab2.id)
        // Second attachment must not share parent-map ownership.
        let otherAttachmentID = UUID()
        renderer.applyParentMapEvents(batchB, attachmentID: otherAttachmentID)
        #expect(renderer.parentMap.parent(of: tree.pane.id) == tab2.id)
    }

    @Test func heuristicOnceSkipsAfterSatisfied() {
        var renderer = NestedTopologyTwoPassRenderer()
        let paneID = NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1")
        let key = NestedAssociationKey(
            nodeID: paneID,
            sessionRawID: "session-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        #expect(renderer.shouldRunHeuristic(for: key))
        renderer.markHeuristicSatisfied(for: key, parentID: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t1"))
        #expect(!renderer.shouldRunHeuristic(for: key))
    }

    @Test func controlSocketPayloadUsesSnakeCaseAndStructuredIDs() throws {
        var service = NestedTopologyReadService()
        let result = service.list(attachments: [liveAttachment(snapshot: NestedTopologyFixtures.snapshot())])
        let object = try #require(NestedTopologyControlSocketPayload().foundationObject(for: result))

        #expect(object["encoding_version"] as? Int == 1)
        let capabilities = try #require(object["capabilities"] as? [String])
        #expect(capabilities == ["nested_topology.focus.v1", "nested_topology.read.v1"])

        let attachments = try #require(object["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        let nodes = try #require(attachments[0]["nodes"] as? [[String: Any]])
        let pane = try #require(nodes.first { ($0["id"] as? [String: Any])?["node_kind"] as? String == "pane" })
        let id = try #require(pane["id"] as? [String: Any])
        #expect(id["provider_kind"] as? String == "herdr")
        #expect(id["raw_id"] as? String == "w1:p1")
        #expect(pane["host_surface_id"] as? String == NestedTopologyFixtures.hostSurfaceID.uuidString)
        #expect(pane["parent_id"] != nil)
        #expect(NestedTopologyControlSocketPayload().includeNestedRequested(["include_nested": true]))
        #expect(!NestedTopologyControlSocketPayload().includeNestedRequested([:]))
    }

    @Test func sidebarSubtreeBuildsHierarchyWithoutBonsplitIdentity() {
        var service = NestedTopologyReadService()
        let subtree = service.sidebarSubtree(
            for: liveAttachment(snapshot: NestedTopologyFixtures.snapshot()),
            isExpanded: true
        )
        #expect(subtree.isExpanded)
        #expect(subtree.roots.count == 1)
        #expect(subtree.roots[0].children.count == 1)
        #expect(subtree.roots[0].children[0].children.count == 1)
        #expect(subtree.accessibilityLabel.contains("herdr"))
        #expect(subtree.roots[0].accessibilityLabel.contains("workspace"))
    }

    @Test func hostSurfaceFilterScopesList() {
        var service = NestedTopologyReadService()
        let a = liveAttachment(snapshot: NestedTopologyFixtures.snapshot())
        var b = a
        b.hostStableSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        b.attachmentID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let filtered = service.list(
            attachments: [a, b],
            hostStableSurfaceID: NestedTopologyFixtures.hostSurfaceID
        )
        #expect(filtered.attachments.count == 1)
        #expect(filtered.attachments[0].hostStableSurfaceID == NestedTopologyFixtures.hostSurfaceID)
    }

    @Test func titleLockSurvivesProjectionOfASecondAttachment() throws {
        var service = NestedTopologyReadService()
        let snapshotA = NestedTopologyFixtures.snapshot(instance: NestedTopologyFixtures.instanceA)
        let snapshotB = NestedTopologyFixtures.snapshot(instance: NestedTopologyFixtures.instanceB)

        let key = NestedAssociationKey(
            nodeID: snapshotA.panes[0].id,
            sessionRawID: snapshotA.panes[0].id.rawID,
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        service.lockTitle(for: key, title: "Locked Pane", authority: .user)

        var attachmentA = liveAttachment(snapshot: snapshotA)
        attachmentA.providerInstanceID = NestedTopologyFixtures.instanceA

        var attachmentB = liveAttachment(snapshot: snapshotB)
        attachmentB.attachmentID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        attachmentB.hostStableSurfaceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        attachmentB.providerInstanceID = NestedTopologyFixtures.instanceB

        _ = service.list(attachments: [attachmentA, attachmentB])
        let second = service.list(attachments: [attachmentA, attachmentB])

        let projectedA = try #require(
            second.attachments.first { $0.providerInstanceID == NestedTopologyFixtures.instanceA }
        )
        let paneLabel = try #require(projectedA.nodes.first { $0.id.kind == .pane }?.label)
        #expect(paneLabel == "Locked Pane")
    }

    private func liveAttachment(snapshot: NestedTopologySnapshot) -> NestedAttachmentRecord {
        NestedAttachmentRecord(
            attachmentID: NestedTopologyFixtures.attachmentID,
            hostWorkspaceID: "workspace:1",
            hostStableSurfaceID: NestedTopologyFixtures.hostSurfaceID,
            providerKind: .herdr,
            providerInstanceID: NestedTopologyFixtures.instanceA,
            capabilities: NestedCapabilitySet(capabilities: [.topologySnapshotV1]),
            state: .live,
            latestSnapshot: snapshot
        )
    }
}

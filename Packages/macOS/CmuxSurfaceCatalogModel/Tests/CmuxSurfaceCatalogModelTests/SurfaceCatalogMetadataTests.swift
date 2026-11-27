import CmuxSurfaceCatalogModel
import Foundation
import Testing

@Suite struct SurfaceCatalogMetadataTests {
    @Test func pendingWorkspaceMetadataRoundTrips() throws {
        let machine = SurfaceMachineID.cloud("vm-1")
        let nativeWorkspaceID = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            pendingWorkspaceCreations: [machine: ["workspace-1": nativeWorkspaceID]],
            pendingWorkspaceDeletions: [machine: ["workspace-2"]],
            machines: [],
            resources: [],
            projections: [],
            staleMachineIDs: [machine]
        )
        let decoded = try JSONDecoder().decode(
            SurfaceCatalogSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.pendingWorkspaceCreations?[machine]?["workspace-1"] == nativeWorkspaceID)
    }

    @Test func legacySnapshotOmitsOptionalMetadata() throws {
        let data = Data(#"{"machines":[],"resources":[],"projections":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(SurfaceCatalogSnapshot.self, from: data)
        #expect(snapshot.pendingWorkspaceCreations == nil)
        #expect(snapshot.pendingWorkspaceDeletions == nil)
        #expect(snapshot.staleMachineIDs.isEmpty)
    }

    @Test func exportKeepsStableOwnersSeparateFromRuntimeSelectors() {
        let projection = SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("vm-1"), kind: .terminal, key: "term-1"),
            workspaceID: UUID(),
            panelID: UUID()
        )
        let identity = SurfaceProjectionIdentity(stableSurfaceID: UUID(), stableWorkspaceID: UUID())
        let snapshot = SurfaceCatalogSnapshot(machines: [], resources: [], projections: [projection])
        let export = SurfaceCatalogExport(
            catalog: snapshot,
            cloudStates: [],
            projectionIdentities: [projection: identity]
        )
        #expect(export.catalog.projections == [projection])
        #expect(export.projectionIdentities[projection] == identity)
        #expect(export.projectionIdentities[projection]?.stableSurfaceID != projection.panelID)
        #expect(export.projectionIdentities[projection]?.stableWorkspaceID != projection.workspaceID)
        #expect(SurfaceCatalogExport(catalog: snapshot, cloudStates: []).projectionIdentities.isEmpty)
    }
}

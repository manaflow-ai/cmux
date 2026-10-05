import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

struct SidebarMultiSelectionSnapshotTests {
    @Test func nativeSelectionRoundTripsWithoutConflatingFocusAndSelection() throws {
        let first = UUID(), second = UUID()
        let snapshot = CmuxSidebarSnapshot(sequence: 1, selectedWorkspaceID: second,
            selectedWorkspaceIDs: [first], selectionAnchorWorkspaceID: first,
            workspaces: [.init(id: first, title: "First"), .init(id: second, title: "Second")])
        let decoded = try JSONDecoder().decode(CmuxSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.selectedWorkspaceID == second)
        #expect(decoded.selectedWorkspaceIDs == [first])
        #expect(decoded.selectionAnchorWorkspaceID == first)
    }

    @Test func explicitEmptySelectionStaysEmpty() throws {
        let snapshot = CmuxSidebarSnapshot(sequence: 1, selectedWorkspaceID: UUID(), selectedWorkspaceIDs: [], workspaces: [])
        let decoded = try JSONDecoder().decode(CmuxSidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.selectedWorkspaceIDs.isEmpty)
    }

    @Test func olderSnapshotsDefaultToFocusedWorkspace() throws {
        let selected = UUID()
        let snapshot = CmuxSidebarSnapshot(sequence: 1, selectedWorkspaceID: selected, workspaces: [])
        var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        wire.removeValue(forKey: "selectedWorkspaceIDs")
        wire.removeValue(forKey: "selectionAnchorWorkspaceID")
        let decoded = try JSONDecoder().decode(CmuxSidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(decoded.selectedWorkspaceIDs == [selected])
        #expect(decoded.selectionAnchorWorkspaceID == nil)
    }

    @Test func selectionMetadataRequiresMetadataGrant() {
        let selected = UUID()
        let snapshot = CmuxSidebarSnapshot(sequence: 1, selectedWorkspaceID: selected,
            selectedWorkspaceIDs: [selected], selectionAnchorWorkspaceID: selected,
            workspaces: [.init(id: selected, title: "Private")])
        let filtered = snapshot.filtered(for: [.workspaceList])
        #expect(filtered.selectedWorkspaceID == nil)
        #expect(filtered.selectedWorkspaceIDs.isEmpty)
        #expect(filtered.selectionAnchorWorkspaceID == nil)
        let denied = snapshot.filtered(for: [])
        #expect(denied.selectedWorkspaceIDs.isEmpty)
    }
}

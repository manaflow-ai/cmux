import CmuxExtensionKit
import Testing

@testable import CMUXSampleSidebarExtension

@Suite
struct CMUXSampleSidebarExtensionTests {
    @Test
    func testManifestMatchesSidebarContract() throws {
        let manifest = CMUXExtensionManifest.cmuxSampleSidebar

        try CMUXExtensionValidator.validateSidebarManifest(manifest)
        #expect(manifest.kind == .sidebar)
        #expect(manifest.minimumAPIVersion == .sidebarV1)
        #expect(manifest.requestedScopes.contains(.workspaceMetadata))
    }

    @Test
    func testSampleExtensionReturnsSnapshot() async throws {
        let sidebar = CMUXSampleSidebarExtension()

        let snapshot = try await sidebar.makeInitialSnapshot()

        #expect(snapshot.apiVersion == .sidebarV1)
        #expect(snapshot.workspaces.count == 2)
        #expect(snapshot.selectedWorkspaceID == snapshot.workspaces.first?.id)
    }

    @Test
    func testSampleExtensionAcceptsSelectWorkspace() async throws {
        let sidebar = CMUXSampleSidebarExtension()
        let workspaceID = try #require(CMUXSidebarSnapshot.sample.selectedWorkspaceID)

        let result = try await sidebar.handle(.selectWorkspace(workspaceID))

        #expect(result.accepted)
    }
}

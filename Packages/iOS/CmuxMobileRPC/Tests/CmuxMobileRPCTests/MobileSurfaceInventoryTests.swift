import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileSurfaceInventoryTests {
    @Test func absentInventoryDecodesAsNil() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"{"workspaces":[{"id":"w","title":"W","is_selected":true,"terminals":[]}]}"#.utf8))
        #expect(response.workspaces.first?.surfaces == nil)
        #expect(MobileWorkspacePreview(remote: response.workspaces[0]).surfaces.isEmpty)
    }

    @Test func unknownKindSurvivesProjection() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(#"{"workspaces":[{"id":"w","title":"W","is_selected":true,"terminals":[],"surfaces":[{"surface_id":"s","kind":"future.canvas","title":"Canvas","file_path":"/tmp/a"}]}]}"#.utf8))
        let surface = try #require(MobileWorkspacePreview(remote: response.workspaces[0]).surfaces.first)
        #expect(surface.kind == .other("future.canvas"))
        #expect(surface.filePath == "/tmp/a")
    }
}

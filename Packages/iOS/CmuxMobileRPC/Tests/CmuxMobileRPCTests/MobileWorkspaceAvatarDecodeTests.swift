import Foundation
import Testing

import CmuxMobileShellModel
@testable import CmuxMobileRPC

/// Decode + remote-mapping tests for the additive per-workspace `avatar` field
/// on the `workspace.list` RPC. The field must decode when present, tolerate a
/// Mac old enough not to emit it (absent → nil), and flow into the preview so
/// the phone can render a per-workspace avatar.
@Suite struct MobileWorkspaceAvatarDecodeTests {
    private func decodeFirstWorkspace(_ json: String) throws -> MobileSyncWorkspaceListResponse.Workspace {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(json.utf8))
        return try #require(response.workspaces.first)
    }

    @Test func decodesAvatarWhenPresent() throws {
        let json = #"""
        {"workspaces":[
          {"id":"w1","title":"Build","is_selected":false,"terminals":[],"avatar":"logo:claude"}
        ]}
        """#
        let workspace = try decodeFirstWorkspace(json)
        #expect(workspace.avatar == "logo:claude")
    }

    @Test func avatarIsNilWhenMacDoesNotEmitIt() throws {
        // A Mac old enough not to emit `avatar` omits the key entirely; the
        // synthesized decoder must treat the optional as absent (nil), not throw.
        let json = #"""
        {"workspaces":[
          {"id":"w1","title":"Build","is_selected":false,"terminals":[]}
        ]}
        """#
        let workspace = try decodeFirstWorkspace(json)
        #expect(workspace.avatar == nil)
    }

    @Test func remoteMappingCarriesAvatarIntoPreview() throws {
        let json = #"""
        {"workspaces":[
          {"id":"w1","title":"Build","is_selected":false,"terminals":[],"avatar":"logo:codex"}
        ]}
        """#
        let workspace = try decodeFirstWorkspace(json)
        let preview = MobileWorkspacePreview(remote: workspace)
        #expect(preview.avatar == "logo:codex")
    }

    @Test func remoteMappingLeavesAvatarNilWhenAbsent() throws {
        let json = #"""
        {"workspaces":[
          {"id":"w1","title":"Build","is_selected":false,"terminals":[]}
        ]}
        """#
        let workspace = try decodeFirstWorkspace(json)
        let preview = MobileWorkspacePreview(remote: workspace)
        #expect(preview.avatar == nil)
    }
}

import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileRPC

/// Decode tests for the workspace-picture (iMessage-style avatar) wire shapes:
/// the `picture_hash` field on the workspace-list payload and the
/// `mobile.workspace.picture.get` fetch-by-hash response.
@Suite struct MobileWorkspacePictureDecodeTests {
    @Test func workspaceListDecodesPictureHash() throws {
        let json = #"""
        {"workspaces":[{"id":"ws-1","title":"Build","current_directory":null,"is_selected":true,"is_pinned":false,"picture_hash":"a1b2c3d4e5f60718","terminals":[]}]}
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(json.utf8))
        let workspace = try #require(response.workspaces.first)
        #expect(workspace.pictureHash == "a1b2c3d4e5f60718")
    }

    @Test func workspaceListToleratesMissingAndNullPictureHash() throws {
        let json = #"""
        {"workspaces":[
            {"id":"ws-1","title":"NoField","is_selected":false,"terminals":[]},
            {"id":"ws-2","title":"NullField","is_selected":false,"picture_hash":null,"terminals":[]}
        ]}
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(json.utf8))
        #expect(response.workspaces.count == 2)
        #expect(response.workspaces[0].pictureHash == nil)
        #expect(response.workspaces[1].pictureHash == nil)
    }

    @Test func remoteMappingCarriesPictureHashIntoPreview() throws {
        let json = #"""
        {"workspaces":[{"id":"ws-1","title":"Build","is_selected":false,"picture_hash":"deadbeef00112233","terminals":[]}]}
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(json.utf8))
        let remote = try #require(response.workspaces.first)
        let preview = MobileWorkspacePreview(remote: remote)
        #expect(preview.pictureHash == "deadbeef00112233")
        #expect(preview.pictureData == nil)
    }

    @Test func pictureResponseDecodesImageBytes() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let json = """
        {"workspace_id":"ws-1","hash":"a1b2c3d4e5f60718","image_base64":"\(pngBytes.base64EncodedString())"}
        """
        let response = try MobileWorkspacePictureResponse.decode(Data(json.utf8))
        #expect(response.workspaceID == "ws-1")
        #expect(response.hash == "a1b2c3d4e5f60718")
        #expect(response.imageData == pngBytes)
    }

    @Test func pictureResponseTreatsNullImageAsAbsent() throws {
        let json = #"{"workspace_id":"ws-1","hash":"a1b2c3d4e5f60718","image_base64":null}"#
        let response = try MobileWorkspacePictureResponse.decode(Data(json.utf8))
        #expect(response.imageData == nil)
    }

    @Test func pictureResponseTreatsEmptyAndInvalidBase64AsAbsent() throws {
        let empty = try MobileWorkspacePictureResponse.decode(
            Data(#"{"workspace_id":"ws-1","hash":"h","image_base64":""}"#.utf8)
        )
        #expect(empty.imageData == nil)
        let invalid = try MobileWorkspacePictureResponse.decode(
            Data(#"{"workspace_id":"ws-1","hash":"h","image_base64":"%%%not-base64%%%"}"#.utf8)
        )
        #expect(invalid.imageData == nil)
    }
}

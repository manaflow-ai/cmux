import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileWorkspaceDiffEligibilityTests {
    @Test func workspaceListMapsDiffEligibilityFromRemoteKind() throws {
        let json = Data("""
        {
          "workspaces": [
            {
              "id": "local",
              "title": "Local",
              "is_selected": true,
              "is_remote_workspace": false,
              "is_remote_tmux_mirror": false,
              "terminals": []
            },
            {
              "id": "remote",
              "title": "Remote",
              "is_selected": false,
              "is_remote_workspace": true,
              "is_remote_tmux_mirror": false,
              "terminals": []
            }
          ]
        }
        """.utf8)

        let response = try MobileSyncWorkspaceListResponse.decode(json)

        #expect(MobileWorkspacePreview(remote: response.workspaces[0]).isDiffReviewEligible)
        #expect(!MobileWorkspacePreview(remote: response.workspaces[1]).isDiffReviewEligible)
    }
}

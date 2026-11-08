import Foundation
import Testing

@testable import CmuxMobileRPC

@Suite struct MobileWorkspaceChangesSummaryRequestTests {
    @Test func additiveForceFieldDecodesAndDefaultsToFalse() throws {
        let forced = try MobileWorkspaceChangesSummaryRequest.decode(
            Data(#"{"workspace_ids":["workspace-a"],"force":true}"#.utf8)
        )
        let legacy = try MobileWorkspaceChangesSummaryRequest.decode(
            Data(#"{"workspace_ids":["workspace-a"]}"#.utf8)
        )

        #expect(forced.workspaceIDs == ["workspace-a"])
        #expect(forced.force)
        #expect(!legacy.force)
    }
}

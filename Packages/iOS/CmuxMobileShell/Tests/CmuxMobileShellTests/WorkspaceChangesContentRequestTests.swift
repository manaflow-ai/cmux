import Testing

@testable import CmuxMobileShell

@Suite struct WorkspaceChangesContentRequestTests {
    @Test func revisionRawValuesMatchTheWireContract() {
        #expect(WorkspaceChangesFileRevision.current.rawValue == "current")
        #expect(WorkspaceChangesFileRevision.base.rawValue == "base")
    }

    @Test func statRequestCarriesWorkspacePathAndBaseRevision() {
        let request = WorkspaceChangesContentRequest.stat(
            workspaceID: "workspace-1",
            path: "old/image.png",
            revision: .base
        )

        #expect(request.method == "mobile.workspace.changes.file_stat")
        #expect(request.params["workspace_id"] as? String == "workspace-1")
        #expect(request.params["path"] as? String == "old/image.png")
        #expect(request.params["revision"] as? String == "base")
    }

    @Test func fetchRequestCarriesCurrentRevisionAndSlice() {
        let request = WorkspaceChangesContentRequest.fetch(
            workspaceID: "workspace-2",
            path: "movie.mov",
            revision: .current,
            offset: 3_145_728,
            length: 3_145_728
        )

        #expect(request.method == "mobile.workspace.changes.file_fetch")
        #expect(request.params["workspace_id"] as? String == "workspace-2")
        #expect(request.params["path"] as? String == "movie.mov")
        #expect(request.params["revision"] as? String == "current")
        #expect(request.params["offset"] as? Int64 == 3_145_728)
        #expect(request.params["length"] as? Int == 3_145_728)
    }
}

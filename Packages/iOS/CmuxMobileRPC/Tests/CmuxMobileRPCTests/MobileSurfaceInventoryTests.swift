import CMUXMobileCore
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
        #expect(surface.todo == nil)
    }

    @Test func todoSnapshotSurvivesLegacyWorkspaceProjection() throws {
        let data = Data(#"{"workspaces":[{"id":"w","title":"W","is_selected":true,"terminals":[],"surfaces":[{"surface_id":"todo-1","kind":"todo","title":"Todo","todo":{"status":"review","status_hidden":false,"items":[{"id":"item-1","text":"Ship it","state":"in_progress","origin":"user"}]}}]}]}"#.utf8)
        let response = try MobileSyncWorkspaceListResponse.decode(data)
        let surface = try #require(MobileWorkspacePreview(remote: response.workspaces[0]).surfaces.first)
        let todo = try #require(surface.todo)

        #expect(surface.kind == .todo)
        #expect(todo.status == .review)
        #expect(todo.statusHidden == false)
        #expect(todo.items == [
            MobileTodoItem(
                id: "item-1",
                text: "Ship it",
                state: .inProgress,
                origin: .user
            ),
        ])
    }
}

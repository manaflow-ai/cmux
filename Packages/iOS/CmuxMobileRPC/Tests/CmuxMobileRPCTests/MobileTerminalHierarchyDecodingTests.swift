import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileRPC

@Test func workspaceListResponseDecodesPaneHierarchyAndClosePolicy() throws {
    let json = Data("""
    {
      "workspaces": [{
        "id": "ws-1",
        "title": "Project",
        "is_selected": true,
        "focused_pane_id": "pane-left",
        "selected_terminal_id": "terminal-b",
        "panes": [
          {"id":"pane-left","spatial_index":0,"is_focused":true,"terminal_ids":["terminal-a","terminal-b"]},
          {"id":"pane-right","spatial_index":1,"is_focused":false,"terminal_ids":["terminal-c"]}
        ],
        "terminals": [
          {"id":"terminal-a","title":"shell","pane_id":"pane-left","is_focused":false,"can_close":true,"requires_close_confirmation":false},
          {"id":"terminal-b","title":"shell","pane_id":"pane-left","is_focused":true,"can_close":true,"requires_close_confirmation":true},
          {"id":"terminal-c","title":"logs","pane_id":"pane-right","is_focused":false,"can_close":false,"requires_close_confirmation":false}
        ]
      }]
    }
    """.utf8)

    let response = try MobileSyncWorkspaceListResponse.decode(json)
    let remote = try #require(response.workspaces.first)
    let workspace = MobileWorkspacePreview(remote: remote)
    #expect(workspace.focusedPaneID == "pane-left")
    #expect(workspace.selectedTerminalID == "terminal-b")
    #expect(workspace.resolvedPanes.map(\.id) == ["pane-left", "pane-right"])
    #expect(workspace.terminals(in: "pane-left").map(\.id) == ["terminal-a", "terminal-b"])
    #expect(workspace.terminals.first(where: { $0.id == "terminal-b" })?.requiresCloseConfirmation == true)
    #expect(workspace.terminals.first(where: { $0.id == "terminal-c" })?.canClose == false)
}

@Test func legacyTerminalPayloadFailsClosedAndGetsCompatibilityPane() throws {
    let json = Data("""
    {"workspaces":[{"id":"ws-legacy","title":"Legacy","is_selected":true,
      "terminals":[{"id":"terminal-a","title":"shell","is_focused":true}]}]}
    """.utf8)

    let response = try MobileSyncWorkspaceListResponse.decode(json)
    let remote = try #require(response.workspaces.first)
    let workspace = MobileWorkspacePreview(remote: remote)
    let terminal = try #require(workspace.terminals.first)
    let pane = try #require(workspace.resolvedPanes.first)
    #expect(!terminal.canClose)
    #expect(terminal.requiresCloseConfirmation)
    #expect(workspace.resolvedPanes.count == 1)
    #expect(pane.terminalIDs == [terminal.id])
}

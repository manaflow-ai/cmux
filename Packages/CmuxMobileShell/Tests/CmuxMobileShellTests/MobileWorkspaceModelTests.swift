import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the workspace/selection state carved into
/// ``MobileWorkspaceModel``: remote-list application with snapshot
/// preservation, merge semantics, ticket-target selection, and terminal
/// selection reconciliation.
@MainActor
@Suite struct MobileWorkspaceModelTests {
    @Test func applyRemoteListPreservesViewportFitForExistingTerminals() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", terminals: [terminalJSON(id: "t-1")]),
        ]))
        let fit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 80, rows: 24),
            client: MobileTerminalViewportSize(columns: 100, rows: 30),
            isCurrentClientLimiting: false
        )
        model.workspaces[0].terminals[0].viewportFit = fit

        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", title: "Renamed", terminals: [terminalJSON(id: "t-1"), terminalJSON(id: "t-2")]),
        ]))

        #expect(model.workspaces[0].name == "Renamed")
        #expect(model.workspaces[0].terminals[0].viewportFit == fit)
        #expect(model.workspaces[0].terminals[1].viewportFit == nil)
    }

    @Test func mergeModeUpdatesByIDAndAppendsNewWorkspaces() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", terminals: [terminalJSON(id: "t-1")]),
            workspaceJSON(id: "ws-2", terminals: [terminalJSON(id: "t-2")]),
        ]))

        model.applyRemoteWorkspaceList(
            try response(workspaces: [
                workspaceJSON(id: "ws-2", title: "Updated", terminals: [terminalJSON(id: "t-2")]),
                workspaceJSON(id: "ws-3", terminals: [terminalJSON(id: "t-3")]),
            ]),
            mergeExistingWorkspaces: true
        )

        #expect(model.workspaces.map(\.id.rawValue) == ["ws-1", "ws-2", "ws-3"])
        #expect(model.workspaces[1].name == "Updated")
    }

    @Test func preferActiveTicketTargetSelectsTicketWorkspaceAndTerminal() throws {
        let model = MobileWorkspaceModel(workspaces: [])

        model.applyRemoteWorkspaceList(
            try response(workspaces: [
                workspaceJSON(id: "ws-1", isSelected: true, terminals: [terminalJSON(id: "t-1")]),
                workspaceJSON(id: "ws-2", terminals: [terminalJSON(id: "t-2a"), terminalJSON(id: "t-2b")]),
            ]),
            preferActiveTicketTarget: true,
            activeTicketWorkspaceID: "ws-2",
            activeTicketTerminalID: "t-2b"
        )

        #expect(model.selectedWorkspaceID?.rawValue == "ws-2")
        #expect(model.selectedTerminalID?.rawValue == "t-2b")
    }

    @Test func ticketTargetMissingFromListFallsBackToRemoteSelection() throws {
        let model = MobileWorkspaceModel(workspaces: [])

        model.applyRemoteWorkspaceList(
            try response(workspaces: [
                workspaceJSON(id: "ws-1", terminals: [terminalJSON(id: "t-1")]),
                workspaceJSON(id: "ws-2", isSelected: true, terminals: [terminalJSON(id: "t-2")]),
            ]),
            preferActiveTicketTarget: true,
            activeTicketWorkspaceID: "ws-gone",
            activeTicketTerminalID: nil
        )

        #expect(model.selectedWorkspaceID?.rawValue == "ws-2")
        #expect(model.selectedTerminalID?.rawValue == "t-2")
    }

    @Test func existingSelectionSurvivesListRefresh() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [terminalJSON(id: "t-1")]),
            workspaceJSON(id: "ws-2", terminals: [terminalJSON(id: "t-2")]),
        ]))
        model.setSelectedWorkspaceID("ws-2")

        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [terminalJSON(id: "t-1")]),
            workspaceJSON(id: "ws-2", terminals: [terminalJSON(id: "t-2")]),
        ]))

        #expect(model.selectedWorkspaceID?.rawValue == "ws-2")
        #expect(model.selectedTerminalID?.rawValue == "t-2")
    }

    @Test func selectionReconciliationPrefersReadyFocusedTerminal() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [
                terminalJSON(id: "t-unready", isReady: false),
                terminalJSON(id: "t-ready", isReady: true),
                terminalJSON(id: "t-ready-focused", isReady: true, isFocused: true),
            ]),
        ]))

        #expect(model.selectedTerminalID?.rawValue == "t-ready-focused")
    }

    @Test func unreadySelectionIsReplacedOnceWorkspaceHasReadyTerminal() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [
                terminalJSON(id: "t-pending", isReady: false),
            ]),
        ]))
        #expect(model.selectedTerminalID?.rawValue == "t-pending")

        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [
                terminalJSON(id: "t-pending", isReady: false),
                terminalJSON(id: "t-live", isReady: true),
            ]),
        ]))

        #expect(model.selectedTerminalID?.rawValue == "t-live")
    }

    @Test func selectingWorkspaceWithoutTerminalsClearsTerminalSelection() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", isSelected: true, terminals: [terminalJSON(id: "t-1")]),
            workspaceJSON(id: "ws-empty", terminals: []),
        ]))

        model.selectedWorkspaceID = "ws-empty"

        #expect(model.selectedTerminalID == nil)
    }

    @Test func workspaceIDForTerminalIDResolvesOwningWorkspace() throws {
        let model = MobileWorkspaceModel(workspaces: [])
        model.applyRemoteWorkspaceList(try response(workspaces: [
            workspaceJSON(id: "ws-1", terminals: [terminalJSON(id: "t-1")]),
            workspaceJSON(id: "ws-2", terminals: [terminalJSON(id: "t-2")]),
        ]))

        #expect(model.workspaceID(forTerminalID: "t-2")?.rawValue == "ws-2")
        #expect(model.workspaceID(forTerminalID: "t-unknown") == nil)
    }

    // MARK: - Helpers

    private func response(workspaces: [[String: Any]]) throws -> MobileSyncWorkspaceListResponse {
        let data = try JSONSerialization.data(withJSONObject: ["workspaces": workspaces])
        return try MobileSyncWorkspaceListResponse.decode(data)
    }

    private func workspaceJSON(
        id: String,
        title: String? = nil,
        isSelected: Bool = false,
        terminals: [[String: Any]]
    ) -> [String: Any] {
        [
            "id": id,
            "title": title ?? id,
            "current_directory": "/Users/test/\(id)",
            "is_selected": isSelected,
            "terminals": terminals,
        ]
    }

    private func terminalJSON(
        id: String,
        isReady: Bool = true,
        isFocused: Bool = false
    ) -> [String: Any] {
        [
            "id": id,
            "title": id,
            "current_directory": "/Users/test",
            "is_ready": isReady,
            "is_focused": isFocused,
        ]
    }
}

import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test func scopedReportPwdBurstUsesZeroMainHopsAndOneReplacementScope() {
        let context = FakeSidebarV1ControlCommandContext()
        context.tabManagerAvailable = false
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let replies = (0..<39).map { index in
            coordinator.handleSidebarV1(
                command: "report_pwd",
                args: "/tmp/scoped-\(index) --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
            )
        }

        #expect(replies.allSatisfy { $0 == "OK" })
        #expect(context.mainHopCount == 0)
        #expect(context.scheduledDirectoryUpdates.count == 39)
        let replacementScopes = Set(context.scheduledDirectoryUpdates.map {
            "\($0.scope.workspaceID.uuidString):\($0.scope.panelID.uuidString):directory"
        })
        #expect(replacementScopes.count == 1)
        #expect(context.scheduledDirectoryUpdates.allSatisfy {
            $0.scope == ControlSidebarPanelScope(workspaceID: workspaceID, panelID: panelID)
        })
        #expect(context.scheduledDirectoryUpdates.last?.directory == "/tmp/scoped-38")
        // The live seam maps this one distinct scope to
        // TerminalMutationReplaceKey(workspace, panel, .directory), bounding
        // the pending bus entries for the burst at one last-write-wins slot.
    }

    @Test func scopedReportPwdPreservesDisplayLabelAndFilesystemPathWithoutMainHop() throws {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "report_pwd",
            args: "\"Friendly Repo\" --path=/actual/repo --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.mainHopCount == 0)
        #expect(context.scheduledDirectoryUpdates.count == 1)
        let update = try #require(context.scheduledDirectoryUpdates.first)
        #expect(update.directory == "/actual/repo")
        #expect(update.displayLabel == "Friendly Repo")
    }

    @Test func scopedReportPwdParseErrorsStayOffMainAndDoNotEnqueue() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let scope = "--tab=\(UUID().uuidString) --panel=\(UUID().uuidString)"

        #expect(
            coordinator.handleSidebarV1(command: "report_pwd", args: scope) ==
                "ERROR: Missing path — usage: report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y]"
        )
        #expect(
            coordinator.handleSidebarV1(command: "report_pwd", args: "label --path= \(scope)") ==
                "ERROR: Missing filesystem path — usage: report_pwd <display-label> --path=/actual/path [--tab=X] [--panel=Y]"
        )
        #expect(context.mainHopCount == 0)
        #expect(context.scheduledDirectoryUpdates.isEmpty)
    }

    @Test func unscopedReportPwdRetainsAvailabilityAndSynchronousWriteSemantics() throws {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        context.tabManagerAvailable = false
        #expect(
            coordinator.handleSidebarV1(command: "report_pwd", args: "") ==
                "ERROR: TabManager not available"
        )
        #expect(context.mainHopCount == 1)

        context.tabManagerAvailable = true
        #expect(
            coordinator.handleSidebarV1(command: "report_pwd", args: "") ==
                "ERROR: Missing path — usage: report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y]"
        )
        #expect(context.mainHopCount == 2)

        context.directoryUpdateResult = .done
        let panelID = UUID()
        #expect(
            coordinator.handleSidebarV1(
                command: "report_pwd",
                args: "/tmp/fallback --tab=2 --panel=\(panelID.uuidString)"
            ) == "OK"
        )
        #expect(context.mainHopCount == 3)
        let call = try #require(context.directoryUpdateCall)
        #expect(call.tabArg == "2")
        #expect(call.panelArg == panelID.uuidString)
        #expect(call.directory == "/tmp/fallback")
        #expect(call.displayLabel == nil)
    }

    @Test func unscopedReportPwdRetainsPanelResolutionErrors() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let missingPanelID = UUID()

        let cases: [(args: String, result: ControlSidebarPanelWriteResolution, expected: String)] = [
            ("/tmp/repo --tab=2", .tabNotFound, "ERROR: Tab not found"),
            ("/tmp/repo", .tabNotFound, "ERROR: No tab selected"),
            (
                "/tmp/repo --tab=2 --panel=",
                .missingPanelArg,
                "ERROR: Missing panel id — usage: report_pwd <path|display-label> [--path=/actual/path] [--tab=X] [--panel=Y]"
            ),
            ("/tmp/repo --tab=2 --panel=bad", .invalidPanelArg("bad"), "ERROR: Invalid panel id 'bad'"),
            ("/tmp/repo --tab=2", .noFocusedPanel, "ERROR: Missing panel id (no focused surface)"),
            (
                "/tmp/repo --tab=2 --panel=\(missingPanelID.uuidString)",
                .panelNotFound(missingPanelID),
                "ERROR: Panel not found '\(missingPanelID.uuidString)'"
            ),
        ]

        for testCase in cases {
            context.directoryUpdateResult = testCase.result
            #expect(
                coordinator.handleSidebarV1(command: "report_pwd", args: testCase.args) ==
                    testCase.expected
            )
        }
        #expect(context.mainHopCount == cases.count)
        #expect(context.scheduledDirectoryUpdates.isEmpty)
    }

    @Test func workspaceLoadingFailureReasonReturnsErrorLine() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(
            before: false,
            after: false,
            failureReason: "Manual workspace loading limit reached"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "workspace_loading",
            args: "manual on --tab=workspace-1"
        )

        #expect(response == "ERROR: Manual workspace loading limit reached")
        #expect(context.workspaceLoadingCall?.tabArg == "workspace-1")
        #expect(context.workspaceLoadingCall?.key == "manual")
        #expect(context.workspaceLoadingCall?.on == true)
    }

    @Test func workspaceLoadingRejectsExplicitEmptyTabBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(before: false, after: true)
        let coordinator = ControlCommandCoordinator(context: context)

        let blankForms = [
            "manual on --tab",
            "manual on --tab=",
        ]

        for args in blankForms {
            let response = coordinator.handleSidebarV1(
                command: "workspace_loading",
                args: args
            )

            #expect(response == "ERROR: Invalid --tab; expected a workspace id, ref, or index")
            #expect(context.workspaceLoadingCall == nil)
        }
    }
}

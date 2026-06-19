import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the v1 window/workspace
/// line-protocol dispatch (`handleWindowV1` / `handleWorkspaceV1`) without the
/// app target. Records the raw args each witness received and returns canned
/// reply lines.
@MainActor
private final class FakeWindowWorkspaceV1Context: ControlCommandContext {
    var windowSummaries: [ControlWindowSummary] = []

    var currentWindowReply = "current-window"
    var focusWindowReply = "focus-window"
    var newWindowReply = "new-window"
    var closeWindowReply = "close-window"
    var moveWorkspaceToWindowReply = "move-ws"

    var listWorkspacesReply = "list-ws"
    var currentWorkspaceReply = "current-ws"
    var newWorkspaceReply = "new-ws"
    var newSplitReply = "new-split"
    var closeWorkspaceReply = "close-ws"
    var selectWorkspaceReply = "select-ws"

    private(set) var receivedFocusWindowArg: String?
    private(set) var receivedCloseWindowArg: String?
    private(set) var receivedMoveArgs: String?
    private(set) var receivedNewWorkspaceArgs: String?
    private(set) var receivedNewSplitArgs: String?
    private(set) var receivedCloseWorkspaceArg: String?
    private(set) var receivedSelectWorkspaceArg: String?

    func controlWindowSummaries() -> [ControlWindowSummary] { windowSummaries }

    func controlCurrentWindowV1() -> String { currentWindowReply }
    func controlFocusWindowV1(arg: String) -> String {
        receivedFocusWindowArg = arg
        return focusWindowReply
    }
    func controlNewWindowV1() -> String { newWindowReply }
    func controlCloseWindowV1(arg: String) -> String {
        receivedCloseWindowArg = arg
        return closeWindowReply
    }
    func controlMoveWorkspaceToWindowV1(args: String) -> String {
        receivedMoveArgs = args
        return moveWorkspaceToWindowReply
    }

    func controlListWorkspacesV1() -> String { listWorkspacesReply }
    func controlCurrentWorkspaceV1() -> String { currentWorkspaceReply }
    func controlNewWorkspaceV1(args: String) -> String {
        receivedNewWorkspaceArgs = args
        return newWorkspaceReply
    }
    func controlNewSplitV1(args: String) -> String {
        receivedNewSplitArgs = args
        return newSplitReply
    }
    func controlCloseWorkspaceV1(arg: String) -> String {
        receivedCloseWorkspaceArg = arg
        return closeWorkspaceReply
    }
    func controlSelectWorkspaceV1(arg: String) -> String {
        receivedSelectWorkspaceArg = arg
        return selectWorkspaceReply
    }
}

@MainActor
@Suite("ControlCommandCoordinator v1 window/workspace dispatch")
struct ControlCommandCoordinatorWindowWorkspaceV1Tests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeWindowWorkspaceV1Context) {
        let context = FakeWindowWorkspaceV1Context()
        return (ControlCommandCoordinator(context: context), context)
    }

    // MARK: - Dispatch ownership

    @Test func windowDispatchReturnsNilForUnownedCommand() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleWindowV1(command: "list_workspaces", args: "") == nil)
        #expect(coordinator.handleWindowV1(command: "definitely_not_a_command", args: "") == nil)
    }

    @Test func workspaceDispatchReturnsNilForUnownedCommand() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleWorkspaceV1(command: "list_windows", args: "") == nil)
        #expect(coordinator.handleWorkspaceV1(command: "ping", args: "") == nil)
    }

    // MARK: - list_windows formatting (drained into the coordinator)

    @Test func listWindowsRendersFlatLinesMarkingKeyWindow() {
        let (coordinator, context) = makeCoordinator()
        let keyID = UUID()
        let otherID = UUID()
        let selectedWs = UUID()
        context.windowSummaries = [
            ControlWindowSummary(
                windowID: keyID,
                isKeyWindow: true,
                isVisible: true,
                workspaceCount: 3,
                selectedWorkspaceID: selectedWs
            ),
            ControlWindowSummary(
                windowID: otherID,
                isKeyWindow: false,
                isVisible: true,
                workspaceCount: 0,
                selectedWorkspaceID: nil
            ),
        ]
        let reply = coordinator.handleWindowV1(command: "list_windows", args: "")
        let expected = """
        * 0: \(keyID.uuidString) selected_workspace=\(selectedWs.uuidString) workspaces=3
          1: \(otherID.uuidString) selected_workspace=none workspaces=0
        """
        #expect(reply == expected)
    }

    @Test func listWindowsReportsNoWindowsWhenEmpty() {
        let (coordinator, context) = makeCoordinator()
        context.windowSummaries = []
        #expect(coordinator.handleWindowV1(command: "list_windows", args: "") == "No windows")
    }

    // MARK: - Window witness forwarding (raw reply verbatim + args passthrough)

    @Test func currentWindowForwardsToWitness() {
        let (coordinator, context) = makeCoordinator()
        context.currentWindowReply = "WINDOW-ID"
        #expect(coordinator.handleWindowV1(command: "current_window", args: "") == "WINDOW-ID")
    }

    @Test func focusWindowForwardsArgVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleWindowV1(command: "focus_window", args: "  abc-123  ")
        #expect(reply == "focus-window")
        #expect(context.receivedFocusWindowArg == "  abc-123  ")
    }

    @Test func newWindowForwardsToWitness() {
        let (coordinator, context) = makeCoordinator()
        context.newWindowReply = "OK xyz"
        #expect(coordinator.handleWindowV1(command: "new_window", args: "ignored") == "OK xyz")
    }

    @Test func closeWindowForwardsArgVerbatim() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handleWindowV1(command: "close_window", args: "win-1")
        #expect(context.receivedCloseWindowArg == "win-1")
    }

    @Test func moveWorkspaceToWindowForwardsArgsVerbatim() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handleWindowV1(command: "move_workspace_to_window", args: "ws-1 win-2")
        #expect(context.receivedMoveArgs == "ws-1 win-2")
    }

    // MARK: - Workspace witness forwarding

    @Test func listAndCurrentWorkspaceForwardToWitness() {
        let (coordinator, context) = makeCoordinator()
        context.listWorkspacesReply = "L"
        context.currentWorkspaceReply = "C"
        #expect(coordinator.handleWorkspaceV1(command: "list_workspaces", args: "") == "L")
        #expect(coordinator.handleWorkspaceV1(command: "current_workspace", args: "") == "C")
    }

    @Test func newWorkspaceForwardsArgVerbatim() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handleWorkspaceV1(command: "new_workspace", args: "My Title")
        #expect(context.receivedNewWorkspaceArgs == "My Title")
    }

    @Test func newSplitForwardsArgVerbatim() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handleWorkspaceV1(command: "new_split", args: "right panel:2")
        #expect(context.receivedNewSplitArgs == "right panel:2")
    }

    @Test func closeAndSelectWorkspaceForwardArgVerbatim() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handleWorkspaceV1(command: "close_workspace", args: "ws-7")
        _ = coordinator.handleWorkspaceV1(command: "select_workspace", args: "2")
        #expect(context.receivedCloseWorkspaceArg == "ws-7")
        #expect(context.receivedSelectWorkspaceArg == "2")
    }

    // MARK: - Unwired context

    @Test func unwiredContextReturnsUnavailableForMutatingCommands() {
        let coordinator = ControlCommandCoordinator(context: nil)
        let unavailable = "ERROR: control context unavailable"
        #expect(coordinator.handleWindowV1(command: "current_window", args: "") == unavailable)
        #expect(coordinator.handleWindowV1(command: "focus_window", args: "x") == unavailable)
        #expect(coordinator.handleWorkspaceV1(command: "new_split", args: "right") == unavailable)
        #expect(coordinator.handleWorkspaceV1(command: "close_workspace", args: "x") == unavailable)
        // list_windows renders empty rather than erroring when the context is
        // unwired (its data source defaults to no summaries).
        #expect(coordinator.handleWindowV1(command: "list_windows", args: "") == "No windows")
    }
}

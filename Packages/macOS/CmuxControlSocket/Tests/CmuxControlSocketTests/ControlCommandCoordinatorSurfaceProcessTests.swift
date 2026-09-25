import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("Surface process metadata")
struct ControlCommandCoordinatorSurfaceProcessTests {
    @Test(arguments: [false, true])
    func surfaceListLocalProcessesStayOutsideRemoteRelay(relayScoped: Bool) throws {
        let context = FakeSurfaceControlCommandContext()
        let workspaceID = UUID()
        context.surfaceListSnapshot = ControlSurfaceListSnapshot(
            workspaceID: workspaceID,
            windowID: nil,
            surfaces: [ControlSurfaceSummary(
                surfaceID: UUID(), typeRawValue: "terminal", title: "shell",
                isFocused: true, paneID: nil, indexInPane: nil, selectedInPane: true,
                developerToolsVisible: nil, requestedWorkingDirectory: nil,
                initialCommand: nil, tmuxStartCommand: nil, isTerminal: true,
                resumeBinding: nil, controllingTTY: "/dev/ttys123", foregroundProcessID: 4321
            )]
        )
        var params: [String: JSONValue] = ["workspace_id": .string(workspaceID.uuidString)]
        if relayScoped { params["_cmux_remote_workspace_id"] = .string(workspaceID.uuidString) }
        let result = ControlCommandCoordinator(context: context).handle(ControlRequest(
            id: .int(1), method: "surface.list", params: params
        ))
        guard case let .ok(.object(payload)) = result,
              case let .array(rows)? = payload["surfaces"],
              case let .object(row)? = rows.first else {
            Issue.record("Expected a terminal surface row")
            return
        }
        #expect(row["tty"] == (relayScoped ? nil : .string("/dev/ttys123")))
        #expect(row["foreground_pid"] == (relayScoped ? nil : .int(4321)))
    }

}

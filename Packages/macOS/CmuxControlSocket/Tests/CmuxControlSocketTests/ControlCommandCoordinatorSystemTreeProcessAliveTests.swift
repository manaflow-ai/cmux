import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class ProcessAliveSystemContext: ControlCommandContext {
    var resolution = ControlSystemTreeResolution(
        windowFound: true,
        workspaceFound: true,
        windows: []
    )

    func controlSystemTreeWindows(
        requestedWindowID: UUID?,
        includeAllWindows: Bool,
        focusedWindowID: UUID?,
        workspaceFilter: UUID?
    ) -> ControlSystemTreeResolution {
        resolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator system.tree process liveness")
struct ControlCommandCoordinatorSystemTreeProcessAliveTests {
    @Test func serializesFalseTrueAndUnknownWhileSuppressingOnlyExitedTTY() {
        let windowID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        let falseID = UUID()
        let trueID = UUID()
        let unknownID = UUID()
        let surfaces = [
            surface(id: falseID, index: 0, tty: "ttys001", processAlive: false),
            surface(id: trueID, index: 1, tty: "ttys002", processAlive: true),
            surface(id: unknownID, index: 2, tty: "ttys003", processAlive: nil),
        ]
        let context = ProcessAliveSystemContext()
        context.resolution = ControlSystemTreeResolution(
            windowFound: true,
            workspaceFound: true,
            windows: [
                ControlSystemTreeWindowNode(
                    summary: ControlWindowSummary(
                        windowID: windowID,
                        isKeyWindow: true,
                        isVisible: true,
                        workspaceCount: 1,
                        selectedWorkspaceID: workspaceID
                    ),
                    index: 0,
                    workspaces: [
                        ControlSystemTreeWorkspaceNode(
                            workspaceID: workspaceID,
                            index: 0,
                            title: "Workspace",
                            description: nil,
                            isSelected: true,
                            isPinned: false,
                            panes: [
                                ControlSystemTreePaneNode(
                                    paneID: paneID,
                                    index: 0,
                                    isFocused: true,
                                    surfaceIDs: [falseID, trueID, unknownID],
                                    selectedSurfaceID: trueID,
                                    surfaces: surfaces
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )

        let result = ControlCommandCoordinator(context: context).handle(
            ControlRequest(id: .int(1), method: "system.tree", params: [:])
        )
        guard case .ok(.object(let root))? = result,
              case .array(let windows)? = root["windows"],
              case .object(let window) = windows.first,
              case .array(let workspaces)? = window["workspaces"],
              case .object(let workspace) = workspaces.first,
              case .array(let panes)? = workspace["panes"],
              case .object(let pane) = panes.first,
              case .array(let payloads)? = pane["surfaces"] else {
            Issue.record("Expected a system.tree surface payload")
            return
        }

        #expect(payloads.count == 3)
        #expect(field("process_alive", in: payloads[0]) == .bool(false))
        #expect(field("tty", in: payloads[0]) == .null)
        #expect(field("process_alive", in: payloads[1]) == .bool(true))
        #expect(field("tty", in: payloads[1]) == .string("ttys002"))
        #expect(field("process_alive", in: payloads[2]) == .null)
        #expect(field("tty", in: payloads[2]) == .string("ttys003"))
    }

    private func surface(
        id: UUID,
        index: Int,
        tty: String,
        processAlive: Bool?
    ) -> ControlSystemTreeSurfaceNode {
        ControlSystemTreeSurfaceNode(
            surfaceID: id,
            index: index,
            typeRawValue: "terminal",
            title: "Terminal",
            isFocused: index == 1,
            isSelected: index == 1,
            selectedInPane: index == 1,
            paneID: nil,
            indexInPane: index,
            tty: tty,
            processAlive: processAlive,
            isBrowser: false,
            url: nil
        )
    }

    private func field(_ key: String, in payload: JSONValue) -> JSONValue? {
        guard case .object(let object) = payload else { return nil }
        return object[key]
    }
}

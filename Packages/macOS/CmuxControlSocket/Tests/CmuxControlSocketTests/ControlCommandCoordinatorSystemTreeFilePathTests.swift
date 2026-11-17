import Foundation
import Testing
@testable import CmuxControlSocket

/// A ``ControlCommandContext`` that returns a fixed `system.tree` walk.
@MainActor
private final class FakeSystemTreeControlCommandContext: ControlCommandContext {
    var windows: [ControlSystemTreeWindowNode] = []

    func controlSystemTreeWindows(
        requestedWindowID: UUID?,
        includeAllWindows: Bool,
        focusedWindowID: UUID?,
        workspaceFilter: UUID?
    ) -> ControlSystemTreeResolution {
        ControlSystemTreeResolution(windowFound: true, workspaceFound: true, windows: windows)
    }
}

@MainActor
@Suite("ControlCommandCoordinator system.tree file paths")
struct ControlCommandCoordinatorSystemTreeFilePathTests {
    private func surfaceNode(
        id: UUID,
        index: Int,
        type: String,
        title: String,
        paneID: UUID,
        filePath: String?
    ) -> ControlSystemTreeSurfaceNode {
        ControlSystemTreeSurfaceNode(
            surfaceID: id,
            index: index,
            typeRawValue: type,
            title: title,
            isFocused: index == 0,
            isSelected: index == 0,
            selectedInPane: index == 0,
            paneID: paneID,
            indexInPane: index,
            tty: nil,
            isBrowser: false,
            url: nil,
            filePath: filePath
        )
    }

    @Test func fileSurfacesEmitTheirPathAndOtherSurfacesEmitNull() throws {
        let context = FakeSystemTreeControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let windowID = UUID()
        let workspaceID = UUID()
        let paneID = UUID()
        let markdownID = UUID()
        let terminalID = UUID()
        let path = "/Users/me/projects/app/docs/handoff.md"

        context.windows = [
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
                                surfaceIDs: [markdownID, terminalID],
                                selectedSurfaceID: markdownID,
                                surfaces: [
                                    surfaceNode(id: markdownID, index: 0, type: "markdown", title: "handoff.md", paneID: paneID, filePath: path),
                                    surfaceNode(id: terminalID, index: 1, type: "terminal", title: "zsh", paneID: paneID, filePath: nil),
                                ]
                            ),
                        ]
                    ),
                ]
            ),
        ]

        let result = coordinator.handle(ControlRequest(id: .int(1), method: "system.tree", params: [:]))
        guard case .ok(.object(let payload)) = result,
              case .array(let windows)? = payload["windows"],
              case .object(let window)? = windows.first,
              case .array(let workspaces)? = window["workspaces"],
              case .object(let workspace)? = workspaces.first,
              case .array(let panes)? = workspace["panes"],
              case .object(let pane)? = panes.first,
              case .array(let surfaces)? = pane["surfaces"] else {
            Issue.record("Unexpected system.tree result: \(result)")
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: surfaces.compactMap { surface -> (String, [String: JSONValue])? in
            guard case .object(let object) = surface, case .string(let id)? = object["id"] else { return nil }
            return (id, object)
        })
        #expect(byID[markdownID.uuidString]?["file_path"] == .string(path))
        #expect(byID[terminalID.uuidString]?["file_path"] == .null)
    }
}

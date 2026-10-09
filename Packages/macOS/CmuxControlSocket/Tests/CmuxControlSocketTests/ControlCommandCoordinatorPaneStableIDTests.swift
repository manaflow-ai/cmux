import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator pane stable IDs")
struct ControlCommandCoordinatorPaneStableIDTests {
    @Test func paneListIncludesStableSurfaceIDs() {
        let context = FakeSurfaceControlCommandContext()
        let workspaceID = UUID()
        let paneID = UUID()
        let surfaceID = UUID()
        let stableSurfaceID = UUID()
        context.paneListSnapshot = ControlPaneListSnapshot(
            workspaceID: workspaceID,
            windowID: nil,
            panes: [ControlPaneSummary(
                paneID: paneID,
                isFocused: true,
                surfaceIDs: [surfaceID],
                stableSurfaceIDs: [stableSurfaceID],
                selectedSurfaceID: surfaceID,
                selectedStableSurfaceID: stableSurfaceID,
                pixelFrame: nil,
                gridSize: nil
            )],
            containerWidth: 100,
            containerHeight: 100
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1), method: "pane.list", params: [:]
        ))

        guard case let .ok(.object(payload)) = result,
              case let .array(panes)? = payload["panes"],
              case let .object(pane)? = panes.first else {
            Issue.record("Expected pane.list payload")
            return
        }
        #expect(pane["stable_surface_ids"] == .array([.string(stableSurfaceID.uuidString)]))
        #expect(pane["selected_stable_surface_id"] == .string(stableSurfaceID.uuidString))
    }

    @Test func paneSurfacesIncludesStableSurfaceID() {
        let context = FakeSurfaceControlCommandContext()
        let workspaceID = UUID()
        let paneID = UUID()
        let surfaceID = UUID()
        let stableSurfaceID = UUID()
        context.paneSurfacesSnapshot = ControlPaneSurfacesSnapshot(
            workspaceID: workspaceID,
            paneID: paneID,
            windowID: nil,
            surfaces: [ControlPaneSurfaceSummary(
                surfaceID: surfaceID,
                stableSurfaceID: stableSurfaceID,
                title: "Terminal",
                typeRawValue: "terminal",
                isSelected: true
            )]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1), method: "pane.surfaces", params: [
                "pane_id": .string(paneID.uuidString),
            ]
        ))

        guard case let .ok(.object(payload)) = result,
              case let .array(surfaces)? = payload["surfaces"],
              case let .object(surface)? = surfaces.first else {
            Issue.record("Expected pane.surfaces payload")
            return
        }
        #expect(surface["stable_id"] == .string(stableSurfaceID.uuidString))
    }
}

import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileSimulatorRPCDTOTests {
    @Test func workspaceListDecodesSimulatorDescriptors() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "workspaces": [
                [
                    "id": "workspace-1",
                    "title": "App",
                    "is_selected": true,
                    "current_directory": NSNull(),
                    "terminals": [],
                    "simulators": [
                        [
                            "panel_id": "sim-1",
                            "workspace_id": "workspace-1",
                            "title": "Simulator",
                            "selected_device_name": "iPhone 17",
                            "selected_device_state": "Booted",
                            "status": "streaming",
                            "is_ready": true,
                            "supports_touch": true,
                            "supports_keyboard": true,
                            "supports_hardware_buttons": true,
                            "supports_rotation": true,
                            "owner_connection_id": "conn-1",
                            "is_owned_by_current_connection": true,
                        ],
                    ],
                ],
            ],
        ])

        let response = try MobileSyncWorkspaceListResponse.decode(data)
        let simulator = try #require(response.workspaces.first?.simulators.first)
        #expect(simulator.panelID == "sim-1")
        #expect(simulator.workspaceID == "workspace-1")
        #expect(simulator.selectedDeviceName == "iPhone 17")
        #expect(simulator.isOwnedByCurrentConnection == true)
    }

    /// Shared payloads (state-sync rows, workspace lists) omit the
    /// personalization field; the decoded descriptor must say "unknown"
    /// (nil), not "not owned" (false).
    @Test func workspaceListDecodesMissingOwnershipAsUnknown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "workspaces": [
                [
                    "id": "workspace-1",
                    "title": "App",
                    "is_selected": true,
                    "current_directory": NSNull(),
                    "terminals": [],
                    "simulators": [
                        [
                            "panel_id": "sim-1",
                            "workspace_id": "workspace-1",
                            "title": "Simulator",
                            "selected_device_name": "iPhone 17",
                            "selected_device_state": "Booted",
                            "status": "streaming",
                            "is_ready": true,
                            "supports_touch": true,
                            "supports_keyboard": true,
                            "supports_hardware_buttons": true,
                            "supports_rotation": true,
                            "owner_connection_id": "conn-1",
                        ],
                    ],
                ],
            ],
        ])

        let response = try MobileSyncWorkspaceListResponse.decode(data)
        let simulator = try #require(response.workspaces.first?.simulators.first)
        #expect(simulator.ownerConnectionID == "conn-1")
        #expect(simulator.isOwnedByCurrentConnection == nil)
    }

    @Test func simulatorPointerRequestUsesWorkspaceScopedWireKeys() throws {
        let data = try MobileSimulatorRPCRequestEncoder().requestData(
            method: "mobile.simulator.input.pointer",
            parameters: MobileSimulatorPointerInput(
                panelID: "sim-1",
                workspaceID: "workspace-1",
                phase: .moved,
                x: 0.25,
                y: 0.75
            )
        )
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        #expect(request["method"] as? String == "mobile.simulator.input.pointer")
        #expect(params["panel_id"] as? String == "sim-1")
        #expect(params["workspace_id"] as? String == "workspace-1")
        #expect(params["phase"] as? String == "moved")
        #expect(params["x"] as? Double == 0.25)
        #expect(params["y"] as? Double == 0.75)
    }
}

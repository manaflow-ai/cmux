public import CMUXMobileCore
import Foundation

extension MobileCoreRPCClient {
    public func listMobileSimulatorPanels(workspaceID: String) async throws -> [MobileSimulatorPanelDescriptor] {
        let data = try await sendSimulatorRequest(
            method: "mobile.simulator.list",
            parameters: MobileSimulatorListParameters(workspaceID: workspaceID)
        )
        return try MobileSimulatorListResponse.decode(data).panels
    }

    public func startMobileSimulatorStream(
        panelID: String,
        workspaceID: String
    ) async throws -> MobileSimulatorPanelDescriptor {
        let data = try await sendSimulatorRequest(
            method: "mobile.simulator.stream.start",
            parameters: MobileSimulatorStreamStartParameters(panelID: panelID, workspaceID: workspaceID)
        )
        return try JSONDecoder().decode(MobileSimulatorPanelDescriptor.self, from: data)
    }

    public func stopMobileSimulatorStream(
        panelID: String,
        workspaceID: String
    ) async throws -> MobileSimulatorCommandResponse {
        let data = try await sendSimulatorRequest(
            method: "mobile.simulator.stream.stop",
            parameters: MobileSimulatorPanelParameters(panelID: panelID, workspaceID: workspaceID)
        )
        return try MobileSimulatorCommandResponse.decode(data)
    }

    public func sendMobileSimulatorPointer(
        _ input: MobileSimulatorPointerInput
    ) async throws -> MobileSimulatorCommandResponse {
        try await sendSimulatorCommand(method: "mobile.simulator.input.pointer", parameters: input)
    }

    public func sendMobileSimulatorText(
        _ input: MobileSimulatorTextInput
    ) async throws -> MobileSimulatorCommandResponse {
        try await sendSimulatorCommand(method: "mobile.simulator.input.text", parameters: input)
    }

    public func sendMobileSimulatorButton(
        _ input: MobileSimulatorButtonInput
    ) async throws -> MobileSimulatorCommandResponse {
        try await sendSimulatorCommand(method: "mobile.simulator.input.button", parameters: input)
    }

    public func listMobileSimulatorDevices(
        panelID: String,
        workspaceID: String
    ) async throws -> [MobileSimulatorDeviceDescriptor] {
        let data = try await sendSimulatorRequest(
            method: "mobile.simulator.devices.list",
            parameters: MobileSimulatorPanelParameters(panelID: panelID, workspaceID: workspaceID)
        )
        return try MobileSimulatorDevicesResponse.decode(data).devices
    }

    public func recoverMobileSimulator(
        panelID: String,
        workspaceID: String
    ) async throws -> MobileSimulatorCommandResponse {
        try await sendSimulatorCommand(
            method: "mobile.simulator.recover",
            parameters: MobileSimulatorPanelParameters(panelID: panelID, workspaceID: workspaceID)
        )
    }

    public func selectMobileSimulatorDevice(
        panelID: String,
        workspaceID: String,
        udid: String
    ) async throws -> MobileSimulatorCommandResponse {
        try await sendSimulatorCommand(
            method: "mobile.simulator.device.select",
            parameters: MobileSimulatorDeviceSelectParameters(
                panelID: panelID, workspaceID: workspaceID, udid: udid)
        )
    }

    private func sendSimulatorCommand<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) async throws -> MobileSimulatorCommandResponse {
        let data = try await sendSimulatorRequest(method: method, parameters: parameters)
        return try MobileSimulatorCommandResponse.decode(data)
    }

    private func sendSimulatorRequest<Parameters: Encodable>(
        method: String,
        parameters: Parameters
    ) async throws -> Data {
        try await sendRequest(MobileSimulatorRPCRequestEncoder().requestData(method: method, parameters: parameters))
    }
}

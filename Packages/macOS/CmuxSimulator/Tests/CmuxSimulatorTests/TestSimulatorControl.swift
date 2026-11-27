@testable import CmuxSimulator

actor TestSimulatorControl: SimulatorControlling {
    private let devices: [SimulatorDevice]
    private(set) var bootDeviceIDs: [String] = []
    private(set) var waitDeviceIDs: [String] = []
    private(set) var shutdownDeviceIDs: [String] = []
    private(set) var actions: [SimulatorControlAction] = []

    init(devices: [SimulatorDevice] = []) {
        self.devices = devices
    }

    func discoverDevices() async throws -> [SimulatorDevice] { devices }
    func boot(deviceID: String) async throws { bootDeviceIDs.append(deviceID) }
    func waitUntilBooted(deviceID: String) async throws { waitDeviceIDs.append(deviceID) }
    func shutdown(deviceID: String) async throws { shutdownDeviceIDs.append(deviceID) }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        return .none
    }
}

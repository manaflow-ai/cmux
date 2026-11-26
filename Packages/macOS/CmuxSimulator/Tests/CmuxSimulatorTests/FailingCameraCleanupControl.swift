@testable import CmuxSimulator

actor FailingCameraCleanupControl: SimulatorControlling {
    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        throw SimulatorFailure(
            code: "fixture_cleanup_failed",
            message: "The fixture relaunch failed.",
            isRecoverable: true
        )
    }
}

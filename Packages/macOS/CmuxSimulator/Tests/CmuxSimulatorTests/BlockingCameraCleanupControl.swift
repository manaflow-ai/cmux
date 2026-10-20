import Foundation
@testable import CmuxSimulator

actor BlockingCameraCleanupControl: SimulatorControlling {
    private(set) var actions: [SimulatorControlAction] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isBlocked = false

    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        if !released, !isBlocked,
           action.isCameraCleanupMutation {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .none
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private extension SimulatorControlAction {
    var isCameraCleanupMutation: Bool {
        switch self {
        case .terminateApplication, .cleanupCameraApplication: true
        default: false
        }
    }
}

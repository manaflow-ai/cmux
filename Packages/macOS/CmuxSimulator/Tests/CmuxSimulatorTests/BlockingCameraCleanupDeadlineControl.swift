import Foundation
@testable import CmuxSimulator

actor BlockingCameraCleanupDeadlineControl: SimulatorControlling {
    private(set) var actions: [SimulatorControlAction] = []
    private(set) var isBlocked = false
    private(set) var blockedCallReturned = false
    private var continuation: CheckedContinuation<Void, Never>?

    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        if !isBlocked, case .terminateApplication = action {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
            blockedCallReturned = true
        }
        return .none
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

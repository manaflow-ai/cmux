import Foundation
@testable import CmuxSimulator

actor BlockingCameraCleanupDeadlineControl: SimulatorControlling {
    private(set) var actions: [SimulatorControlAction] = []
    private(set) var isBlocked = false
    private(set) var blockedCallReturned = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var returnWaiter: CheckedContinuation<Void, Never>?

    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        if !isBlocked, action.isCameraCleanupMutation {
            isBlocked = true
            blockedWaiter?.resume()
            blockedWaiter = nil
            await withCheckedContinuation { continuation = $0 }
            blockedCallReturned = true
            returnWaiter?.resume()
            returnWaiter = nil
        }
        return .none
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func waitUntilBlockedCallReturns() async {
        guard !blockedCallReturned else { return }
        await withCheckedContinuation { returnWaiter = $0 }
    }

    func release() {
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

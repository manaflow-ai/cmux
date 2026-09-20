import Foundation
import CmuxComputerUseCore

/// Commits one verified setup attempt across both daemon profiles, or withdraws it.
@MainActor
struct ComputerUseOnboardingAdmissionCoordinator {
    let store: ComputerUseOnboardingStore
    let publish: @MainActor (ComputerUseDaemonProfile) async -> Bool
    let stop: @MainActor () async -> Void

    func finish(
        _ verification: ComputerUseDirectScreenCaptureVerification,
        attempt: UUID
    ) async -> ComputerUseDirectScreenCaptureVerification {
        let result = store.stageVerification(verification, attempt: attempt)
        guard result == .ready else {
            await withdraw()
            return result
        }
        for profile in ComputerUseDaemonProfile.allCases {
            guard await publish(profile) else {
                await withdraw()
                return .unavailable
            }
        }
        guard store.commitVerification(attempt: attempt) else {
            await withdraw()
            return .unavailable
        }
        for profile in ComputerUseDaemonProfile.allCases {
            guard await publish(profile) else {
                await withdraw()
                return .unavailable
            }
        }
        return .ready
    }

    func withdraw() async {
        store.invalidateCompletion()
        var withdrawn = true
        for profile in ComputerUseDaemonProfile.allCases {
            let acknowledged = await publish(profile)
            withdrawn = acknowledged && withdrawn
        }
        // An unacknowledged withdrawal is ambiguous. Stop the owned helpers
        // rather than leave a previously admitted profile serving tools.
        if !withdrawn { await stop() }
    }
}

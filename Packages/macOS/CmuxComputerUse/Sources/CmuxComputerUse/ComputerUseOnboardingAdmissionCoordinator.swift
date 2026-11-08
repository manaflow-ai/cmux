import Foundation

/// Commits one verified setup attempt across both daemon profiles, or withdraws it.
@MainActor
public struct ComputerUseOnboardingAdmissionCoordinator {
    public let store: ComputerUseOnboardingStore
    public let publish: @MainActor (ComputerUseDaemonProfile) async -> Bool
    public let stop: @MainActor () async -> Void

    public init(
        store: ComputerUseOnboardingStore,
        publish: @escaping @MainActor (ComputerUseDaemonProfile) async -> Bool,
        stop: @escaping @MainActor () async -> Void
    ) {
        self.store = store
        self.publish = publish
        self.stop = stop
    }

    public func finish(
        _ verification: ComputerUseDirectScreenCaptureVerification,
        attempt: UUID
    ) async -> ComputerUseDirectScreenCaptureVerification {
        let result = store.stageVerification(verification, attempt: attempt)
        guard result == .ready else {
            await withdraw()
            return result
        }
        // Close every profile before changing durable state. A retry or crash
        // therefore starts from a known fail-closed barrier.
        guard await publishAll() else {
            await withdraw()
            return .unavailable
        }
        guard store.commitVerification(attempt: attempt) else {
            await withdraw()
            return .unavailable
        }
        // Both readiness writes are issued together and the transaction does
        // not complete until both authenticated profiles acknowledge them.
        guard await publishAll() else {
            await withdraw()
            return .unavailable
        }
        return .ready
    }

    private func publishAll() async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for profile in ComputerUseDaemonProfile.allCases {
                group.addTask { await publish(profile) }
            }
            for await acknowledged in group where !acknowledged { return false }
            return true
        }
    }

    public func withdraw() async {
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

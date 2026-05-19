import Foundation

typealias ManagedSettingsWriteBackShouldContinue = @Sendable () async -> Bool

actor ManagedSettingsWriteBackCoordinator {
    private var generation: UInt64 = 0
    private var writeTail: Task<Void, Never>?

    func invalidate() async {
        generation &+= 1
        let pendingWrite = writeTail
        await pendingWrite?.value
    }

    func schedule(
        work: @escaping @Sendable (ManagedSettingsWriteBackShouldContinue) async throws -> ManagedSettingsWriteBackOutcome
    ) async -> Result<ManagedSettingsWriteBackOutcome, Error>? {
        generation &+= 1
        let currentGeneration = generation
        let previousWrite = writeTail
        let task = Task.detached(priority: .utility) { () -> Result<ManagedSettingsWriteBackOutcome, Error>? in
            await previousWrite?.value
            let shouldContinue: ManagedSettingsWriteBackShouldContinue = {
                await self.isCurrent(currentGeneration)
            }
            guard await shouldContinue() else { return nil }
            do {
                let outcome = try await work(shouldContinue)
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }
        writeTail = Task { _ = await task.value }
        guard let result = await task.value else { return nil }
        guard currentGeneration == generation else { return nil }
        return result
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

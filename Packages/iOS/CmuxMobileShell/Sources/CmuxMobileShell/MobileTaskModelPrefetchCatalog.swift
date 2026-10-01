internal import CmuxMobileShellModel
internal import Foundation

/// One backend response shared by all Macs and providers in a prefetch wave.
struct MobileTaskModelPrefetchCatalog: Sendable {
    let id = UUID()
    let startedAt: Date
    private let waiter: MobileTaskModelPrefetchCatalogWaiter

    init(client: MobileTaskModelCatalogClient, startedAt: Date) {
        self.startedAt = startedAt
        let task = Task { try await client.allResults() }
        let waiter = MobileTaskModelPrefetchCatalogWaiter(task: task)
        self.waiter = waiter
        Task { await waiter.start() }
    }

    func result(for provider: MobileTaskAgentProvider) async -> MobileTaskModelListResult? {
        await waiter.result(for: provider)
    }

    func cancel() {
        Task { await waiter.cancel() }
    }
}

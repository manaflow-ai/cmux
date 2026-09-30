internal import CmuxMobileShellModel
internal import Foundation

/// One backend response shared by all Macs and providers in a prefetch wave.
struct MobileTaskModelPrefetchCatalog: Sendable {
    let startedAt: Date
    private let task: Task<[MobileTaskAgentProvider: MobileTaskModelListResult], Never>

    init(client: MobileTaskModelCatalogClient, startedAt: Date) {
        self.startedAt = startedAt
        task = Task { await client.allResults() }
    }

    func result(for provider: MobileTaskAgentProvider) async -> MobileTaskModelListResult? {
        await task.value[provider]
    }

    func cancel() {
        task.cancel()
    }
}

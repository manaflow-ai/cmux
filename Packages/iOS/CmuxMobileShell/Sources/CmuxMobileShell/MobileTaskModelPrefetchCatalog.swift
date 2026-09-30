internal import CmuxMobileShellModel
internal import Foundation

/// One backend response shared by all Macs and providers in a prefetch wave.
struct MobileTaskModelPrefetchCatalog: Sendable {
    let id = UUID()
    let startedAt: Date
    private let task: Task<[MobileTaskAgentProvider: MobileTaskModelListResult], any Error>

    init(client: MobileTaskModelCatalogClient, startedAt: Date) {
        self.startedAt = startedAt
        task = Task { try await client.allResults() }
    }

    func result(for provider: MobileTaskAgentProvider) async -> MobileTaskModelListResult? {
        try? await task.value[provider]
    }

    func cancel() {
        task.cancel()
    }
}

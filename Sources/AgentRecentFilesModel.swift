import Foundation
import Observation

/// Main-actor projection of recent agent file edits for the active workspace.
@MainActor
@Observable
final class AgentRecentFilesModel {
    private(set) var files: [AgentRecentFile] = []
    private(set) var isLoading = false

    private let provider: any AgentRecentFileProviding
    @ObservationIgnored private var activeScope: AgentRecentFileScope?
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(provider: any AgentRecentFileProviding) {
        self.provider = provider
    }

    deinit {
        observationTask?.cancel()
    }

    func activate(scope: AgentRecentFileScope) {
        guard activeScope != scope || observationTask == nil else { return }
        observationTask?.cancel()
        activeScope = scope
        files = []
        isLoading = true

        let changes = provider.changes()
        observationTask = Task { [weak self] in
            await self?.reload(scope: scope)
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.reload(scope: scope)
            }
        }
    }

    func deactivate(scope: AgentRecentFileScope) {
        guard activeScope == scope else { return }
        observationTask?.cancel()
        observationTask = nil
        activeScope = nil
        isLoading = false
    }

    private func reload(scope: AgentRecentFileScope) async {
        let nextFiles = await provider.recentFiles(in: scope, limit: 24)
        guard !Task.isCancelled, activeScope == scope else { return }
        files = nextFiles
        isLoading = false
    }
}

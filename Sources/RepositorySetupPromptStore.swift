import CmuxSettings
import Foundation
import Observation

@MainActor
@Observable
final class RepositorySetupPromptStore {
    private(set) var prompts: [UUID: RepositorySetupPrompt] = [:]
    private(set) var dismissalFailures: Set<UUID> = []

    private let configStore: JSONConfigStore
    private let catalog: SettingCatalog

    init(configStore: JSONConfigStore, catalog: SettingCatalog) {
        self.configStore = configStore
        self.catalog = catalog
    }

    func show(_ prompt: RepositorySetupPrompt) {
        prompts[prompt.workspaceID] = prompt
        dismissalFailures.remove(prompt.workspaceID)
    }

    func remove(workspaceID: UUID) {
        prompts.removeValue(forKey: workspaceID)
        dismissalFailures.remove(workspaceID)
    }

    func remove(repositoryID: String) {
        let workspaceIDs = prompts.compactMap { workspaceID, prompt in
            prompt.resolution.identity.id == repositoryID ? workspaceID : nil
        }
        for workspaceID in workspaceIDs {
            remove(workspaceID: workspaceID)
        }
    }

    func dismiss(_ prompt: RepositorySetupPrompt) async {
        let repositoryID = prompt.resolution.identity.id
        let repositoryRoot = prompt.resolution.identity.workTreeRoot
        do {
            try await configStore.update(for: catalog.terminal.repositoryScripts) { current in
                var updated = current
                if let index = updated.firstIndex(where: {
                    $0.repositoryID == repositoryID
                }) {
                    updated[index].promptDismissed = true
                } else {
                    updated.append(RepositoryScriptPreference(
                        repositoryID: repositoryID,
                        repositoryRoot: repositoryRoot,
                        promptDismissed: true
                    ))
                }
                return updated
            }
            remove(repositoryID: repositoryID)
        } catch {
            dismissalFailures.insert(prompt.workspaceID)
        }
    }
}

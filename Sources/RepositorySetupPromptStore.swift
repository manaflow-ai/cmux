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
        var preferences = await configStore.value(for: catalog.terminal.repositoryScripts)
        if let index = preferences.firstIndex(where: {
            $0.repositoryID == prompt.resolution.identity.id
        }) {
            preferences[index].promptDismissed = true
        } else {
            preferences.append(RepositoryScriptPreference(
                repositoryID: prompt.resolution.identity.id,
                repositoryRoot: prompt.resolution.identity.workTreeRoot,
                promptDismissed: true
            ))
        }
        do {
            try await configStore.set(preferences, for: catalog.terminal.repositoryScripts)
            remove(repositoryID: prompt.resolution.identity.id)
        } catch {
            dismissalFailures.insert(prompt.workspaceID)
        }
    }
}

import CmuxSettings
import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func repositoryScriptSettingsContext() async -> RepositoryScriptSettingsContext? {
        guard let appDelegate = AppDelegate.shared,
              let runtime = appDelegate.settingsRuntime,
              let directory = appDelegate.activeTabManagerForCommands()?
                .selectedWorkspace?.currentDirectory else {
            return nil
        }
        let preferences = runtime.jsonStore.snapshotValue(for: runtime.catalog.terminal.repositoryScripts)
        guard let resolution = await RepositoryScriptResolver().resolve(
            directory: directory,
            preferences: preferences
        ) else { return nil }
        return RepositoryScriptSettingsContext(
            repositoryName: URL(fileURLWithPath: resolution.identity.workTreeRoot).lastPathComponent,
            repositoryRoot: resolution.identity.workTreeRoot,
            setup: resolution.setup ?? "",
            archive: resolution.archive ?? "",
            projectSetup: resolution.projectScripts.normalized.setup,
            projectArchive: resolution.projectScripts.normalized.archive
        )
    }

    func saveRepositoryScripts(setup: String, archive: String) async -> Bool {
        guard let appDelegate = AppDelegate.shared,
              let runtime = appDelegate.settingsRuntime,
              let tabManager = appDelegate.activeTabManagerForCommands(),
              let workspace = tabManager.selectedWorkspace else { return false }
        let directory = workspace.currentDirectory
        let preferences = await runtime.jsonStore.value(for: runtime.catalog.terminal.repositoryScripts)
        guard let resolution = await RepositoryScriptResolver().resolve(
            directory: directory,
            preferences: preferences
        ) else { return false }
        let normalizedSetup = Self.nonblankRepositoryScript(setup)
        let preference = RepositoryScriptPreference(
            repositoryID: resolution.identity.id,
            repositoryRoot: resolution.identity.workTreeRoot,
            setup: normalizedSetup,
            archive: Self.nonblankRepositoryScript(archive),
            overridesProjectScripts: true,
            promptDismissed: normalizedSetup != nil
        )
        do {
            try await runtime.jsonStore.update(for: runtime.catalog.terminal.repositoryScripts) { current in
                var updated = current
                if let index = updated.firstIndex(where: { $0.repositoryID == resolution.identity.id }) {
                    updated[index] = preference
                } else {
                    updated.append(preference)
                }
                return updated
            }
            tabManager.repositorySetupPromptStore?.remove(repositoryID: resolution.identity.id)
            return true
        } catch {
            return false
        }
    }

    func importProjectRepositoryScripts() async -> Bool {
        guard let context = await repositoryScriptSettingsContext() else { return false }
        return await saveRepositoryScripts(
            setup: context.projectSetup ?? "",
            archive: context.projectArchive ?? ""
        )
    }

    private static func nonblankRepositoryScript(_ script: String) -> String? {
        script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : script
    }
}

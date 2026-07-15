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
            repositoryID: resolution.identity.id,
            repositoryName: URL(fileURLWithPath: resolution.identity.workTreeRoot).lastPathComponent,
            repositoryRoot: resolution.identity.workTreeRoot,
            setup: resolution.setup ?? "",
            archive: resolution.archive ?? "",
            projectSetup: resolution.projectScripts.normalized.setup,
            projectArchive: resolution.projectScripts.normalized.archive
        )
    }

    func saveRepositoryScripts(
        context: RepositoryScriptSettingsContext,
        setup: String,
        archive: String
    ) async -> RepositoryScriptSettingsContext? {
        guard let appDelegate = AppDelegate.shared,
              let runtime = appDelegate.settingsRuntime else { return nil }
        let preferences = await runtime.jsonStore.value(for: runtime.catalog.terminal.repositoryScripts)
        guard let resolution = await RepositoryScriptResolver().resolve(
            directory: context.repositoryRoot,
            preferences: preferences
        ), resolution.identity.id == context.repositoryID,
           resolution.identity.workTreeRoot == context.repositoryRoot else { return nil }
        let normalizedSetup = Self.nonblankRepositoryScript(setup)
        let normalizedArchive = Self.nonblankRepositoryScript(archive)
        let preference = RepositoryScriptPreference(
            repositoryID: resolution.identity.id,
            repositoryRoot: resolution.identity.workTreeRoot,
            setup: normalizedSetup,
            archive: normalizedArchive,
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
            appDelegate.repositoryScriptRuntime?.promptStore.remove(repositoryID: resolution.identity.id)
            return RepositoryScriptSettingsContext(
                repositoryID: resolution.identity.id,
                repositoryName: URL(fileURLWithPath: resolution.identity.workTreeRoot).lastPathComponent,
                repositoryRoot: resolution.identity.workTreeRoot,
                setup: normalizedSetup ?? "",
                archive: normalizedArchive ?? "",
                projectSetup: resolution.projectScripts.normalized.setup,
                projectArchive: resolution.projectScripts.normalized.archive
            )
        } catch {
            return nil
        }
    }

    func importProjectRepositoryScripts(
        context: RepositoryScriptSettingsContext
    ) async -> RepositoryScriptSettingsContext? {
        return await saveRepositoryScripts(
            context: context,
            setup: context.projectSetup ?? "",
            archive: context.projectArchive ?? ""
        )
    }

    private static func nonblankRepositoryScript(_ script: String) -> String? {
        script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : script
    }
}

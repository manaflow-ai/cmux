import CmuxFoundation
import CmuxSettings

@MainActor
final class RepositoryScriptRuntime {
    let promptStore: RepositorySetupPromptStore
    let lifecycleCoordinator: RepositoryScriptLifecycleCoordinator

    init(
        configStore: JSONConfigStore,
        catalog: SettingCatalog,
        commandRunner: any CommandRunning
    ) {
        let promptStore = RepositorySetupPromptStore(
            configStore: configStore,
            catalog: catalog
        )
        self.promptStore = promptStore
        self.lifecycleCoordinator = RepositoryScriptLifecycleCoordinator(
            configStore: configStore,
            catalog: catalog,
            promptStore: promptStore,
            commandRunner: commandRunner
        )
    }
}

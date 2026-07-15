import CmuxSettings

struct RepositoryScriptResolution: Sendable, Equatable {
    let identity: RepositoryScriptIdentity
    let scripts: CmuxRepositoryScriptsDefinition
    let projectScripts: CmuxRepositoryScriptsDefinition
    let source: RepositoryScriptSource
    let preference: RepositoryScriptPreference?

    var setup: String? { scripts.normalized.setup }
    var archive: String? { scripts.normalized.archive }

    var shouldPromptForSetup: Bool {
        setup == nil && !(preference?.promptDismissed ?? false)
    }
}

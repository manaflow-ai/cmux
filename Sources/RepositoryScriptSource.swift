enum RepositoryScriptSource: Sendable, Equatable {
    case projectFile(path: String)
    case userSettings
    case none
}

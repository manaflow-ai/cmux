/// The active repository scripts displayed by the terminal Settings section.
public struct RepositoryScriptSettingsContext: Sendable, Equatable {
    /// Repository name shown above the script editors.
    public let repositoryName: String

    /// Canonical root of the active work tree.
    public let repositoryRoot: String

    /// Effective setup script after applying the user's private override.
    public let setup: String

    /// Effective archive script after applying the user's private override.
    public let archive: String

    /// Setup script read from the project config, when present.
    public let projectSetup: String?

    /// Archive script read from the project config, when present.
    public let projectArchive: String?

    /// Creates the Settings snapshot for one repository.
    ///
    /// - Parameters:
    ///   - repositoryName: Repository name shown in Settings.
    ///   - repositoryRoot: Canonical work-tree root.
    ///   - setup: Effective setup script.
    ///   - archive: Effective archive script.
    ///   - projectSetup: Project-config setup script.
    ///   - projectArchive: Project-config archive script.
    public init(
        repositoryName: String,
        repositoryRoot: String,
        setup: String,
        archive: String,
        projectSetup: String?,
        projectArchive: String?
    ) {
        self.repositoryName = repositoryName
        self.repositoryRoot = repositoryRoot
        self.setup = setup
        self.archive = archive
        self.projectSetup = projectSetup
        self.projectArchive = projectArchive
    }
}

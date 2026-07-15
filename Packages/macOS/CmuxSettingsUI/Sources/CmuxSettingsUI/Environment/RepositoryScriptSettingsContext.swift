/// The active repository scripts displayed by the terminal Settings section.
public struct RepositoryScriptSettingsContext: Sendable, Equatable {
    /// Stable repository identity shared by linked work trees.
    public let repositoryID: String

    /// Repository name shown above the script editors.
    public let repositoryName: String

    /// Canonical root of the active work tree.
    public let repositoryRoot: String

    /// Private setup-script override, or an empty string when none is configured.
    public let setup: String

    /// Private archive-script override, or an empty string when none is configured.
    public let archive: String

    /// Setup script read from the project config, when present.
    public let projectSetup: String?

    /// Archive script read from the project config, when present.
    public let projectArchive: String?

    /// Creates the Settings snapshot for one repository.
    ///
    /// - Parameters:
    ///   - repositoryID: Stable identity derived from Git's common directory.
    ///   - repositoryName: Repository name shown in Settings.
    ///   - repositoryRoot: Canonical work-tree root.
    ///   - setup: Private setup-script override.
    ///   - archive: Private archive-script override.
    ///   - projectSetup: Project-config setup script.
    ///   - projectArchive: Project-config archive script.
    public init(
        repositoryID: String,
        repositoryName: String,
        repositoryRoot: String,
        setup: String,
        archive: String,
        projectSetup: String?,
        projectArchive: String?
    ) {
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.repositoryRoot = repositoryRoot
        self.setup = setup
        self.archive = archive
        self.projectSetup = projectSetup
        self.projectArchive = projectArchive
    }
}

struct DockConfigIdentity: Equatable, Sendable {
    let sourceIdentifier: String?
    let sourcePath: String?
    let baseDirectory: String
    let executionWorkspaceID: UUID?

    init(
        sourceLocation: DockConfigLocation?,
        baseDirectory: String,
        executionWorkspaceID: UUID? = nil
    ) {
        self.sourceIdentifier = sourceLocation?.canonicalIdentifier
        self.sourcePath = sourceLocation?.path
        self.baseDirectory = baseDirectory
        self.executionWorkspaceID = executionWorkspaceID
    }

    init(
        sourcePath: String?,
        baseDirectory: String,
        executionWorkspaceID: UUID? = nil
    ) {
        self.sourceIdentifier = sourcePath
        self.sourcePath = sourcePath
        self.baseDirectory = baseDirectory
        self.executionWorkspaceID = executionWorkspaceID
    }

    func requiresPanelReload(comparedTo previous: DockConfigIdentity?) -> Bool {
        guard let previous else { return true }
        if self == previous { return false }
        return sourceIdentifier != nil || previous.sourceIdentifier != nil
    }
}

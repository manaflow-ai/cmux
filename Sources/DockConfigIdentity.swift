struct DockConfigIdentity: Equatable, Sendable {
    let sourceIdentifier: String?
    let sourcePath: String?
    let baseDirectory: String

    init(sourceLocation: DockConfigLocation?, baseDirectory: String) {
        self.sourceIdentifier = sourceLocation?.canonicalIdentifier
        self.sourcePath = sourceLocation?.path
        self.baseDirectory = baseDirectory
    }

    init(sourcePath: String?, baseDirectory: String) {
        self.sourceIdentifier = sourcePath
        self.sourcePath = sourcePath
        self.baseDirectory = baseDirectory
    }

    func requiresPanelReload(comparedTo previous: DockConfigIdentity?) -> Bool {
        guard let previous else { return true }
        if self == previous { return false }
        return sourceIdentifier != nil || previous.sourceIdentifier != nil
    }
}

struct DockConfigIdentity: Equatable, Sendable {
    let sourcePath: String?
    let baseDirectory: String

    func requiresPanelReload(comparedTo previous: DockConfigIdentity?) -> Bool {
        guard let previous else { return true }
        if self == previous { return false }
        return sourcePath != nil || previous.sourcePath != nil
    }
}

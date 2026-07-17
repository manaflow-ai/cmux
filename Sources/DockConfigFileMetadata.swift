struct DockConfigFileMetadata: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case directory
        case other
    }

    let exists: Bool
    let kind: Kind?
    let size: Int64?
}

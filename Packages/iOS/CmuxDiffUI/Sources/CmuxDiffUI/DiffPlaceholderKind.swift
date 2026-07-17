enum DiffPlaceholderKind: Sendable, Equatable {
    case binary
    case large
    case renameOnly
    case failed(String)
}

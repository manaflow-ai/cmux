enum GitFileStatus: Equatable, Sendable {
    case modified, added, deleted, renamed, untracked
}

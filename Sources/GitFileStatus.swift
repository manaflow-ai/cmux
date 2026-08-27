enum GitFileStatus: Equatable, Hashable, Sendable {
    case modified, added, deleted, renamed, untracked
}

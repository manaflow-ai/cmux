enum FileExplorerGitStatusDiff: Sendable {
    case unchanged
    case scoped(Set<String>)
    case allVisible
}

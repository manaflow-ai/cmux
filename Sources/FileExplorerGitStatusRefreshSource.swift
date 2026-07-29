enum FileExplorerGitStatusRefreshSource: Sendable, Equatable {
    case local(
        directory: String
    )
    case ssh(
        directory: String,
        destination: String,
        port: Int?,
        identityFile: String?,
        options: [String]
    )
}

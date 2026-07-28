enum WorkspaceCreateWorkingDirectoryCanonicalProbeResult: Equatable, Sendable {
    case valid(String)
    case invalid
    case wrongFileType
}

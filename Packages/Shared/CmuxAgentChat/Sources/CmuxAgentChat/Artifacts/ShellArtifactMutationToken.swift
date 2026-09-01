/// One lexical shell token relevant to artifact mutation detection.
enum ShellArtifactMutationToken: Equatable {
    case word(String)
    case outputRedirect
    case appendRedirect
    case readWriteRedirect
    case boundary
}

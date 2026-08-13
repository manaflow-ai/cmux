import CmuxAgentChat

/// Immutable system-presentation state owned by one artifact page.
struct ChatArtifactViewerFileActionState: Equatable, Sendable {
    #if os(iOS)
    var presentation: ChatArtifactFileActionPresentation? = nil
    #endif
    var isRunning = false
    var failure: ChatArtifactError?

    var showsError: Bool { failure != nil }
}

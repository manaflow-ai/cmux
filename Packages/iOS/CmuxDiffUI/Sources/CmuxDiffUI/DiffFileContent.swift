public import CmuxMobileRPC

/// The currently available body state for one changed file.
public enum DiffFileContent: Sendable, Equatable {
    /// Parsed hunks ready for rendering.
    case loaded([MobileDiffHunk])
    /// Git reported binary content rather than line-oriented hunks.
    case binary
    /// The patch requires an explicit user action before loading.
    case large
    /// A rename or copy has no textual changes to display.
    case renameOnly
    /// Loading failed with a user-presentable message.
    case failed(String)
}

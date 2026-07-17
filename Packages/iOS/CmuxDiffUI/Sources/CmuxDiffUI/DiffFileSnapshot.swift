public import CmuxMobileRPC

/// Immutable summary and body data for one file in a patch set.
public struct DiffFileSnapshot: Identifiable, Sendable, Equatable {
    /// Stable identity within the patch set.
    public var id: String { summary.path }
    /// Summary metadata returned by the mobile diff RPC.
    public let summary: MobileDiffFileSummary
    /// The currently available body state.
    public let content: DiffFileContent

    /// Creates a file snapshot.
    /// - Parameters:
    ///   - summary: Summary metadata for the file.
    ///   - content: The file's current body state.
    public init(summary: MobileDiffFileSummary, content: DiffFileContent) {
        self.summary = summary
        self.content = content
    }
}

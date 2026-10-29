/// A parser-captured artifact occurrence that is not safely recoverable from
/// the size-budgeted visible message stream.
public struct ChatArtifactTranscriptReference: Sendable, Equatable, Codable {
    /// Path token exactly as detected in the raw transcript.
    public let path: String

    /// Provenance established by the originating transcript channel.
    public let provenance: ChatArtifactProvenance

    /// Sequence of the transcript line that contained the occurrence.
    public let seq: Int

    /// Creates a supplemental transcript artifact occurrence.
    ///
    /// - Parameters:
    ///   - path: Path token exactly as detected.
    ///   - provenance: Provenance established by the channel.
    ///   - seq: Sequence of the containing transcript line.
    public init(path: String, provenance: ChatArtifactProvenance, seq: Int) {
        self.path = path
        self.provenance = provenance
        self.seq = seq
    }
}

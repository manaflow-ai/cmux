import Foundation

/// Incremental read position and parse state for one transcript file.
///
/// Values are handed between the ``AgentUsageSampler`` actor and the
/// detached task that reads the file, so everything here is `Sendable`.
struct AgentUsageFileCursor: Sendable {
    /// Usage folded from the lines read so far.
    var accumulator: AgentUsageTranscriptAccumulator
    /// Bytes consumed from the start of the file.
    var byteOffset: UInt64 = 0
    /// Inode of the file when last read (from `fstat` on the open fd).
    var inode: UInt64?
    /// Size and modification time (ns) from the last read's `fstat`; when a
    /// plain `stat` still matches them (and the inode), the file is skipped
    /// without being opened.
    var statSize: UInt64 = 0
    var modificationNanos: Int64 = 0
    /// The first bytes of the file when last read. A mismatch means the file
    /// was rewritten in place, even if it is now larger.
    var head = Data()
    /// Bytes of an incomplete trailing line, awaiting its newline.
    var fragment = Data()
    /// Skip bytes until the next newline (an oversized line, or the partial
    /// first line of a tail read).
    var discardingLine = false

    init(source: AgentUsageSource, catalog: AgentModelCatalog) {
        accumulator = AgentUsageTranscriptAccumulator(source: source, catalog: catalog)
    }
}

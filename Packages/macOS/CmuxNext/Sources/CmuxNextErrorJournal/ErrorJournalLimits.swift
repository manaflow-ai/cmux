/// The bounds that keep the journal cheap: disk, memory, and storms.
public struct ErrorJournalLimits: Sendable, Equatable {
    /// A segment file is compacted into a fresh one once it grows past this many bytes.
    /// Disk use stays below about twice this (the old segment until the new one is written).
    public var segmentBytes: Int
    /// Most distinct fingerprints kept; the least recently seen go first.
    public var maxEntries: Int
    /// Most UTF-8 bytes of a sample message (and of a template).
    public var maxMessageBytes: Int
    /// Most UTF-8 bytes of one context value; at most ``maxContextKeys`` keys.
    public var maxContextValueBytes: Int
    /// Most context keys kept per sample.
    public var maxContextKeys: Int
    /// New fingerprints accepted per source per minute; the rest only count toward one
    /// `too many distinct errors` entry of that source.
    public var newFingerprintsPerMinute: Int
    /// Dirty entries that make the journal write at once instead of after ``flushDelaySeconds``.
    public var flushBatch: Int
    /// How long a change waits for others before it is written.
    public var flushDelaySeconds: Double

    /// Makes limits.
    /// - Parameters:
    ///   - segmentBytes: Compaction threshold; 4 MiB keeps disk use under 8 MiB.
    ///   - maxEntries: Distinct fingerprints kept (1000 × ≤3 KiB fits one segment).
    ///   - maxMessageBytes: Sample and template cap.
    ///   - maxContextValueBytes: Context value cap.
    ///   - maxContextKeys: Context key cap.
    ///   - newFingerprintsPerMinute: Storm guard per source.
    ///   - flushBatch: Write at once at this many changed entries.
    ///   - flushDelaySeconds: Otherwise write this long after the first change.
    public init(segmentBytes: Int = 4 << 20, maxEntries: Int = 1000, maxMessageBytes: Int = 1024,
                maxContextValueBytes: Int = 256, maxContextKeys: Int = 8, newFingerprintsPerMinute: Int = 120,
                flushBatch: Int = 256, flushDelaySeconds: Double = 2) {
        self.segmentBytes = segmentBytes
        self.maxEntries = maxEntries
        self.maxMessageBytes = maxMessageBytes
        self.maxContextValueBytes = maxContextValueBytes
        self.maxContextKeys = maxContextKeys
        self.newFingerprintsPerMinute = newFingerprintsPerMinute
        self.flushBatch = flushBatch
        self.flushDelaySeconds = flushDelaySeconds
    }
}

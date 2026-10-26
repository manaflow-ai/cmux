/// One call site that blocked the main thread, as ``BlockingDetector/sites`` lists it for the
/// `debug.blocking` control command and the Debug menu.
public struct BlockingSite: Sendable, Equatable {
    /// What the call waited on.
    public var kind: BlockingKind
    /// The call site: `Module/File.swift:line` of the code that called the blocking seam or
    /// ``Mutex/withLock(fileID:line:_:)``.
    public var location: String
    /// How many times this site blocked since launch (or since ``BlockingDetector/resetCounts()``).
    public var count: Int

    /// Makes the value from its parts.
    public init(kind: BlockingKind, location: String, count: Int) {
        self.kind = kind
        self.location = location
        self.count = count
    }
}

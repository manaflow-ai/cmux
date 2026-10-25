/// One call site that blocked the main thread, as ``BlockingDetector/sites`` lists it for the
/// `debug.blocking` control command and the Debug menu.
public struct BlockingSite: Sendable, Equatable {
    /// What the call waited on.
    public var kind: BlockingKind
    /// The call site: `Module/File.swift:line` of the code that called the blocking seam or
    /// ``Mutex/withLock(fileID:line:_:)``.
    public var location: String
    /// How many calls at this site ended since launch (or since ``BlockingDetector/resetCounts()``).
    public var count: Int
    /// The wall time those calls blocked the main thread, in nanoseconds: each ``blockingCall(_:fileID:line:_:)``
    /// and each long ``Mutex`` wait adds its time, except one made inside another timed call, whose time is
    /// already in that call's site.
    public var totalNanos: UInt64
    /// The longest of those calls, in nanoseconds (0 as for ``totalNanos``).
    public var maxNanos: UInt64

    /// Makes the value from its parts.
    public init(kind: BlockingKind, location: String, count: Int, totalNanos: UInt64 = 0, maxNanos: UInt64 = 0) {
        self.kind = kind
        self.location = location
        self.count = count
        self.totalNanos = totalNanos
        self.maxNanos = maxNanos
    }
}

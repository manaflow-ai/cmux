/// One call site that blocked the main thread, a shared pool thread or a `.cpu` lane item, or waited on a sync
/// primitive in a lane item (``context``), as
/// ``BlockingDetector/sites`` lists it for the `debug.blocking` control command and the Debug menu.
public struct BlockingSite: Sendable, Equatable {
    /// What the call waited on, or ``BlockingKind/wrongLane`` for a site in ``BlockingContext/cpuLane``.
    public var kind: BlockingKind
    /// What the seam itself waited on (``BlockingKind/fileIO``, ``BlockingKind/systemCall``, ...): ``kind``,
    /// except at a ``BlockingKind/wrongLane`` site, where it says which lane the item belongs on (`.files` for
    /// file I/O, `.system` for any other wait).
    public var seamKind: BlockingKind
    /// The call site: `Module/File.swift:line` of the code that called the blocking seam or
    /// ``Mutex/withLock(fileID:line:_:)``.
    public var location: String
    /// How many calls at this site ended since launch (or since ``BlockingDetector/resetCounts()``).
    public var count: Int
    /// The wall time those calls blocked their thread, in nanoseconds: each ``blockingCall(_:fileID:line:_:)``
    /// and each long main-thread ``Mutex`` wait adds its time, except one made inside another timed call on the
    /// same thread, whose time is already in that call's site.
    public var totalNanos: UInt64
    /// The longest of those calls, in nanoseconds (0 as for ``totalNanos``).
    public var maxNanos: UInt64
    /// Where the calls ran: ``BlockingContext/main``, ``BlockingContext/pool`` or ``BlockingContext/cpuLane``
    /// (kind ``BlockingKind/wrongLane``). Sites are per context: one line
    /// reached on the main thread and on the pool is two sites.
    public var context: BlockingContext

    /// Makes the value from its parts.
    public init(kind: BlockingKind, location: String, count: Int, totalNanos: UInt64 = 0, maxNanos: UInt64 = 0,
                context: BlockingContext = .main, seamKind: BlockingKind? = nil) {
        self.kind = kind
        self.seamKind = seamKind ?? kind
        self.location = location
        self.count = count
        self.totalNanos = totalNanos
        self.maxNanos = maxNanos
        self.context = context
    }
}

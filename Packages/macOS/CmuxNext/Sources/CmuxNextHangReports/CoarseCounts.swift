/// How much the app had open, as buckets (`0`, `1`, `2-5`, `6-10`, `11-30`, `31-100`, `101+`):
/// enough to tell a light session from a heavy one, never an exact number or a name.
public nonisolated struct CoarseCounts: Codable, Sendable, Equatable {
    /// The bucket of open windows.
    public var windows: String
    /// The bucket of local workspaces.
    public var workspaces: String
    /// The bucket of panes in those workspaces.
    public var panes: String
    /// The bucket of tabs in those panes.
    public var tabs: String
    /// The bucket of the background lanes' `userBlocking` queue-wait p99 since launch, in
    /// milliseconds (``waitBucket(nanos:)``): how long work a person waited for sat behind other lane work
    /// (CmuxNextWakeups' `BackgroundWork.userBlockingQueueWaitP99Nanos`). Schema 3 only
    /// (``HangReport/WireSchema/carriesLaneWait``); nil, and so absent from the JSON, in schema 2 and in reports
    /// written before it.
    public var userBlockingWaitP99Ms: String?

    /// Every label ``bucket(_:)`` returns.
    public static let labels = ["0", "1", "2-5", "6-10", "11-30", "31-100", "101+"]

    /// Every label ``waitBucket(nanos:)`` returns: log2 milliseconds, the lanes' own bucket edges.
    public static let waitLabels = ["0-1", "1-2", "2-4", "4-8", "8-16", "16-32", "32-64", "64+"]

    /// Counts the app could not read (no window yet).
    public static let unknown = CoarseCounts(windows: 0, workspaces: 0, panes: 0, tabs: 0)

    /// Makes the value from its parts.
    ///
    /// - Parameter userBlockingWaitP99Nanos: the lanes' user-blocking queue-wait p99 in nanoseconds; nil sends none.
    public init(windows: Int, workspaces: Int, panes: Int, tabs: Int, userBlockingWaitP99Nanos: UInt64? = nil) {
        self.windows = Self.bucket(windows)
        self.workspaces = Self.bucket(workspaces)
        self.panes = Self.bucket(panes)
        self.tabs = Self.bucket(tabs)
        userBlockingWaitP99Ms = userBlockingWaitP99Nanos.map(Self.waitBucket(nanos:))
    }

    /// The ``waitLabels`` label of a duration of `nanos`: `1-2` is 1 ms up to 2 ms.
    public static func waitBucket(nanos: UInt64) -> String {
        let milliseconds = nanos / 1_000_000
        let index = milliseconds == 0 ? 0 : UInt64.bitWidth - milliseconds.leadingZeroBitCount
        return waitLabels[min(index, waitLabels.count - 1)]
    }

    /// The bucket label of `count`.
    public static func bucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1: "1"
        case 2...5: "2-5"
        case 6...10: "6-10"
        case 11...30: "11-30"
        case 31...100: "31-100"
        default: "101+"
        }
    }
}

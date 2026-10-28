public import CmuxNextTrace

/// One watched thread still inside its hang-watch scope ``HangWatch/hangAfterBudget`` past its budget, as the
/// monitor hands it to ``MainThreadWatchdog/onThreadHang``: the registration, the thread
/// that ran the scope, how far past its budget it was and that thread's stack, sampled by its Mach port
/// (``ThreadStackSampler``) while the scope still ran.
public struct ThreadHang: Sendable, Equatable {
    /// The registration's catalog name (``HangWatch/registerThread(_:name:)``, ``HangWatch/registerLane(_:)``).
    public let name: String
    /// What the registered thread runs; nil for a slot whose kind the table no longer holds.
    public let kind: HangWatch.ThreadKind?
    /// The kernel's name of the thread that ran the scope; empty when unnamed.
    public let threadName: String
    /// When the scope's budget passed (`CLOCK_UPTIME_RAW` nanoseconds).
    public let budgetEndNanos: UInt64
    /// How far past its budget the scope was when its stack was sampled.
    public let overrun: Duration
    /// The thread's return addresses, innermost first.
    public let addresses: [UInt]

    /// Makes the value from its parts.
    public init(name: String, kind: HangWatch.ThreadKind?, threadName: String, budgetEndNanos: UInt64, overrun: Duration,
                addresses: [UInt]) {
        self.name = name
        self.kind = kind
        self.threadName = threadName
        self.budgetEndNanos = budgetEndNanos
        self.overrun = overrun
        self.addresses = addresses
    }

    /// ``kind``'s case name (`io`, `lane`, ...), the name hang reports and crash reports use; `other` when unknown.
    public var kindName: String { kind.map { "\($0)" } ?? "other" }
}

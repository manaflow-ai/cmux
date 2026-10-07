/// WireGuard's protocol timers (whitepaper section 6.1). Defaults are the
/// protocol constants; tests shorten them.
public struct WireGuardTimers: Sendable, Hashable {
    public var rekeyAfterTime: Duration
    public var rejectAfterTime: Duration
    public var rekeyAttemptTime: Duration
    public var rekeyTimeout: Duration
    public var keepaliveTimeout: Duration
    public var rekeyAfterMessages: UInt64
    public var rejectAfterMessages: UInt64

    public init(
        rekeyAfterTime: Duration = .seconds(120),
        rejectAfterTime: Duration = .seconds(180),
        rekeyAttemptTime: Duration = .seconds(90),
        rekeyTimeout: Duration = .seconds(5),
        keepaliveTimeout: Duration = .seconds(10),
        rekeyAfterMessages: UInt64 = 1 << 60,
        rejectAfterMessages: UInt64 = UInt64.max - (1 << 13)
    ) {
        self.rekeyAfterTime = rekeyAfterTime
        self.rejectAfterTime = rejectAfterTime
        self.rekeyAttemptTime = rekeyAttemptTime
        self.rekeyTimeout = rekeyTimeout
        self.keepaliveTimeout = keepaliveTimeout
        self.rekeyAfterMessages = rekeyAfterMessages
        self.rejectAfterMessages = rejectAfterMessages
    }
}

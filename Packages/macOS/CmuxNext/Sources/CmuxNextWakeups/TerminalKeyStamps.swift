/// The daemon's times for one terminal key press on its way to its echo: when it received the
/// `send`, when the bytes reached the PTY, when the read that echoes them came back and when it sent that echo, on
/// `CLOCK_UPTIME_RAW` (the clock of `NSEvent.timestamp`), 0 for a stage it did not see. A hosted terminal's write and
/// read are its host's. The echo's `output` event carries them in `key_stages`; a daemon from before this field sends
/// none, and an app from before it ignores the field.
///
/// Chromium's `EventMetrics` takes each dispatch stage's time in the process that saw it
/// (cc/metrics/event_metrics.h); these are the stages of a terminal key that only the daemon sees.
public nonisolated struct TerminalKeyStamps: Sendable, Hashable {
    public var received: UInt64
    public var written: UInt64
    public var read: UInt64
    public var sent: UInt64
    /// Key presses the terminal's stage ring dropped so far: a newer press took the entry of one with no echo yet, or
    /// its echo came after the no-echo window.
    public var lost: UInt64

    public init(received: UInt64, written: UInt64, read: UInt64, sent: UInt64, lost: UInt64 = 0) {
        self.received = received
        self.written = written
        self.read = read
        self.sent = sent
        self.lost = lost
    }

    /// The stamps are on this Mac's clock and in the press's order: every stamped stage lies after `start` (the
    /// press's dispatch) and before `end` (the echo's decode), and none comes before an earlier one. A daemon on
    /// another machine stamps on its own clock, which this refuses.
    public func isOrdered(after start: UInt64, before end: UInt64) -> Bool {
        var last = start
        return received != 0 && Self.follows(received, &last, end) && Self.follows(written, &last, end)
            && Self.follows(read, &last, end) && Self.follows(sent, &last, end)
    }

    /// `stamp` is unstamped, or lies between `last` and `end` (then it becomes `last`).
    private static func follows(_ stamp: UInt64, _ last: inout UInt64, _ end: UInt64) -> Bool {
        guard stamp != 0 else { return true }
        guard stamp >= last, stamp <= end else { return false }
        last = stamp
        return true
    }
}

/// Where a terminal attachment reports the stamps of each key echo it decodes (the app's input latency tracker,
/// local daemons only). Called on the attachment's reader thread; it must not block.
public nonisolated protocol TerminalKeyStampSink: AnyObject, Sendable {
    /// The echo of the key press `flow` (the flow its `send` carried) came with `stamps`, decoded at `decodedAt`
    /// (`CLOCK_UPTIME_RAW` nanoseconds).
    func keyEchoStamped(flow: UInt64, _ stamps: TerminalKeyStamps, decodedAt: UInt64)
}

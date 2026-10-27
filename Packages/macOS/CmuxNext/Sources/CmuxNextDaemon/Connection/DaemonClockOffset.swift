import Foundation

/// A remote daemon's trace clock against this Mac's (p09-observability-116): what a trace recording's meta
/// stores for that machine, and what the exporter's `ClockSnapshot` for it is built from
/// (`cmux_trace::export::RemoteMachine`).
public struct DaemonClockOffset: Sendable, Equatable {
    /// The remote trace clock minus this Mac's trace clock at the same instant, in ns.
    public let offsetNanos: Int64
    /// How far ``offsetNanos`` can be from the true offset: half the round trip of the exchange it came from.
    public let errorBoundNanos: UInt64
    /// This Mac's trace clock when that exchange's answer came.
    public let measuredAtNanos: UInt64
    /// The remote clock (`identify`'s `trace_clock_domain`: `uptime_raw`, `monotonic` or `qpc`).
    public let remoteDomain: String
}

/// One heartbeat `identify` exchange with `trace_clock`: this Mac's trace clock when the ask left and when its answer
/// came, and the remote trace clock the daemon read just before it answered.
public struct DaemonClockSample: Sendable, Equatable {
    public let sentNanos: UInt64
    public let remoteNanos: UInt64
    public let receivedNanos: UInt64
    public let remoteDomain: String

    public init(sentNanos: UInt64, remoteNanos: UInt64, receivedNanos: UInt64, remoteDomain: String) {
        self.sentNanos = sentNanos
        self.remoteNanos = remoteNanos
        self.receivedNanos = receivedNanos
        self.remoteDomain = remoteDomain
    }

    /// The remote read happened somewhere in the round trip; its midpoint is off by at most half of it.
    var offset: DaemonClockOffset {
        let roundTrip = receivedNanos - sentNanos
        let midpoint = sentNanos + roundTrip / 2
        return DaemonClockOffset(offsetNanos: Int64(bitPattern: remoteNanos &- midpoint), errorBoundNanos: roundTrip / 2 + roundTrip % 2,
                                 measuredAtNanos: receivedNanos, remoteDomain: remoteDomain)
    }
}

/// The min-RTT estimate over the last ``window`` exchanges: NTP's clock filter (RFC 5905 section 10) trusts the
/// exchange with the shortest round trip, the one least delayed by queueing on either side, and its bound is half
/// that round trip. A value type the heartbeat keeps under its own lock.
struct DaemonClockFilter: Sendable {
    /// NTP's filter register holds eight samples.
    static let window = 8

    private(set) var samples: [DaemonClockSample] = []

    /// Keeps `sample`, dropping the oldest past ``window``. A sample whose answer predates its ask (a broken clock)
    /// or whose domain differs from the kept ones (another daemon answered) starts over.
    mutating func add(_ sample: DaemonClockSample) {
        guard sample.receivedNanos >= sample.sentNanos else { return }
        if samples.first?.remoteDomain != nil, samples.first?.remoteDomain != sample.remoteDomain { samples.removeAll() }
        samples.append(sample)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Forgets every sample: this Mac slept (its trace clock stopped while a remote one may not have) or the
    /// connection changed daemons.
    mutating func reset() { samples.removeAll() }

    /// The offset of the shortest exchange kept; nil before the first.
    var estimate: DaemonClockOffset? {
        samples.min { $0.receivedNanos - $0.sentNanos < $1.receivedNanos - $1.sentNanos }?.offset
    }
}

import Foundation
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif

/// Settings → Transport → Align Keepalives (off by default): the app's own
/// keepalive timers (the link heartbeat, presence, the Cloud Chief socket)
/// wait for a beat of the Rust core's one keepalive grid
/// (`cmux_mobile_link::keepalive`), so they go out at the same instants as
/// the link ping and the signaling ping, and the radio wakes once for all.
/// Off, every timer keeps its own interval, as before.
public struct KeepaliveBeat: Sendable {
    /// The `UserDefaults` key Settings writes (`CmuxMobilePreferences.Key.alignKeepalives`).
    public static let defaultsKey = "cmuxMobile.settings.alignKeepalives"
    /// The link's and the sockets' aligned period: the WireGuard keepalive
    /// interval, which already holds NAT bindings. Never longer than a
    /// timer's own interval, so no timeout gets looser.
    public static let period: Duration = .seconds(10)
    /// The Cloud Chief socket's aligned period (25 s unaligned): two beats.
    public static let chiefPeriod: Duration = .seconds(20)

    private let delayToBeat: @Sendable (Duration) -> Duration?

    /// `delayToBeat(period)`: how long until the next beat of `period`, or
    /// nil when alignment is off.
    public init(delayToBeat: @escaping @Sendable (Duration) -> Duration?) {
        self.delayToBeat = delayToBeat
    }

    /// How long until the next beat of `period`, strictly after now; nil
    /// when Align Keepalives is off (the caller keeps its own interval).
    public func delay(toNextBeatOf period: Duration) -> Duration? {
        delayToBeat(period)
    }

    /// Whether alignment is on.
    public var isOn: Bool { delayToBeat(Self.period) != nil }

    /// Alignment off: every timer keeps its own interval.
    public static let off = KeepaliveBeat { _ in nil }

    /// The person's setting, read at each use; beats from the Rust grid.
    public static let live = KeepaliveBeat { period in
        guard UserDefaults.standard.bool(forKey: KeepaliveBeat.defaultsKey) else { return nil }
        let periodMs = max(1, period.wholeMilliseconds)
        #if canImport(CmuxMobileLinkFFI)
        return .milliseconds(Int64(clamping: keepaliveBeatDelayMs(periodMs: UInt64(periodMs))))
        #else
        // No Rust core (macOS package tests): the same wall-clock grid.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return .milliseconds(periodMs - nowMs % periodMs)
        #endif
    }

    /// Tells the Rust core the setting (its link ping, tunnel and signaling
    /// socket); read by each dial.
    public static func applySettingToCore(_ defaults: UserDefaults = .standard) {
        #if canImport(CmuxMobileLinkFFI)
        setKeepaliveAlignment(on: defaults.bool(forKey: defaultsKey))
        #endif
    }
}

extension Duration {
    /// The duration in whole milliseconds.
    var wholeMilliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}

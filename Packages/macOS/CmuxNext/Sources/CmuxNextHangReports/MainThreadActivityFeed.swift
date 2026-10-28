import AppKit
public import CmuxNextInputCore
public import CmuxNextMetrics
public import CmuxNextWakeups
public import Foundation

/// Feeds a ``MainThreadReportLedger`` the app's activation notices (through the app's one
/// `AppEvents` adapter) and the person's keys, clicks and scrolls (through its one input tap);
/// Chrome's `DesktopSessionDurationTracker` hears window activation and user events the same way.
/// Input is forwarded at most once a second: an input stamp at most a second old keeps a span to
/// within a second of Chrome's.
///
/// With ``StabilityCounters`` it also counts `stability.active_seconds` (p09-observability-109) by the same rule,
/// in a ledger of its own: at each resign-active, at a quit, and at an input once a minute has gathered, so a crash
/// loses at most that minute. The metrics file keeps what was counted.
///
/// ```swift
/// feed = MainThreadActivityFeed(ledger: ledger, input: inputTap, events: appEvents, isActive: NSApp.isActive)
/// ```
@MainActor
public final class MainThreadActivityFeed {
    /// The shortest gap between two inputs forwarded to the ledger.
    public static let inputStrideNanos: UInt64 = 1_000_000_000

    private let ledger: MainThreadReportLedger
    private var activation: [EventSubscription] = []
    private var subscription: InputSubscription?
    /// The last input stamp forwarded (uptime nanoseconds).
    private var lastForwardedNanos: UInt64?
    /// The active seconds not yet counted into `stability.active_seconds`.
    private var stabilityTime = ActiveTimeLedger()
    private let stability: StabilityCounters?
    private let uptimeNanos: @Sendable () -> UInt64
    /// The active seconds an input counts once they have gathered.
    static let stabilityStrideSeconds = 60

    /// Starts feeding `ledger`; it stops when this is released.
    ///
    /// - Parameters:
    ///   - ledger: The ledger the next report reads.
    ///   - input: The app's input tap.
    ///   - events: The app's `AppEvents` (one observer per notice for the whole app).
    ///   - isActive: Whether the app is active now (a span starts at once).
    ///   - stability: Where the active seconds are counted; nil counts none.
    ///   - uptimeNanos: The clock of the activation stamps (`CLOCK_UPTIME_RAW`, the clock of `NSEvent.timestamp`).
    public init(ledger: MainThreadReportLedger, input: any InputObserving, events: AppEvents, isActive: Bool,
                stability: StabilityCounters? = nil,
                uptimeNanos: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.ledger = ledger
        self.stability = stability
        self.uptimeNanos = uptimeNanos
        if isActive { becameActive() }
        activation = [
            // raw-observer-allow: subscribed through the app's AppEvents adapter, one observer per notice for the app
            events.subscribe(NSApplication.didBecomeActiveNotification, owner: "MainThreadActivityFeed") { [weak self] in
                self?.becameActive()
            },
            // raw-observer-allow: as above
            events.subscribe(NSApplication.didResignActiveNotification, owner: "MainThreadActivityFeed") { [weak self] in
                self?.resignedActive()
            },
        ]
        subscription = input.observe([.key, .button, .scroll]) { [weak self] record in
            self?.noteInput(timestamp: record.timestamp)
        }
    }

    // perf-hot: 100ns main-turn (every key, button and scroll the app dispatches: one compare, the ledger once a second)
    private func noteInput(timestamp: Double) {
        guard timestamp > 0, let nanos = UInt64(exactly: (timestamp * 1_000_000_000).rounded(.down)) else { return }
        if let last = lastForwardedNanos, nanos >= last, nanos - last < Self.inputStrideNanos { return }
        lastForwardedNanos = nanos
        ledger.didReceiveUserInput(atNanos: nanos)
        guard stability != nil else { return }
        stabilityTime.didReceiveUserInput(atNanos: nanos)
        countActiveSeconds(atNanos: nanos, atLeast: Self.stabilityStrideSeconds)
    }

    /// The app is quitting: the active seconds not yet counted go into the metrics file.
    public func applicationWillTerminate() {
        countActiveSeconds(atNanos: uptimeNanos(), atLeast: 1)
    }

    private func becameActive() {
        ledger.didBecomeActive()
        if stability != nil { stabilityTime.didBecomeActive(atNanos: uptimeNanos()) }
    }

    private func resignedActive() {
        ledger.didResignActive()
        guard stability != nil else { return }
        let now = uptimeNanos()
        stabilityTime.didResignActive(atNanos: now)
        countActiveSeconds(atNanos: now, atLeast: 1)
    }

    /// Counts the whole active seconds gathered up to `nanos` into `stability.active_seconds` once there are at
    /// least `minimum`; the fraction of a second stays for the next count.
    private func countActiveSeconds(atNanos nanos: UInt64, atLeast minimum: Int) {
        guard let stability else { return }
        let seconds = stabilityTime.seconds(atNanos: nanos)
        guard seconds >= minimum else { return }
        stability.active(seconds: seconds)
        stabilityTime.commit(seconds: seconds, atNanos: nanos)
    }
}

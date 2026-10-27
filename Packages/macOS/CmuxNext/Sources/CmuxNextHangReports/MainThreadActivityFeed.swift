#if canImport(AppKit)
import AppKit
public import CmuxNextInputCore
public import CmuxNextWakeups
public import Foundation

/// Feeds a ``MainThreadReportLedger`` the app's activation notices (through the app's one
/// `AppEvents` adapter) and the person's keys, clicks and scrolls (through its one input tap);
/// Chrome's `DesktopSessionDurationTracker` hears window activation and user events the same way.
/// Input is forwarded at most once a second: an input stamp at most a second old keeps a span to
/// within a second of Chrome's.
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

    /// Starts feeding `ledger`; it stops when this is released.
    ///
    /// - Parameters:
    ///   - ledger: The ledger the next report reads.
    ///   - input: The app's input tap.
    ///   - events: The app's `AppEvents` (one observer per notice for the whole app).
    ///   - isActive: Whether the app is active now (a span starts at once).
    public init(ledger: MainThreadReportLedger, input: any InputObserving, events: AppEvents, isActive: Bool) {
        self.ledger = ledger
        if isActive { ledger.didBecomeActive() }
        activation = [
            // raw-observer-allow: subscribed through the app's AppEvents adapter, one observer per notice for the app
            events.subscribe(NSApplication.didBecomeActiveNotification, owner: "MainThreadActivityFeed") { ledger.didBecomeActive() },
            // raw-observer-allow: as above
            events.subscribe(NSApplication.didResignActiveNotification, owner: "MainThreadActivityFeed") { ledger.didResignActive() },
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
    }
}
#endif

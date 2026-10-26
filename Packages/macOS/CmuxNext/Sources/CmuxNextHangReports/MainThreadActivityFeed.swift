import CmuxNextCompat
public import CmuxNextInputCore
public import Foundation

/// Feeds a ``MainThreadReportLedger`` the app's activation notices and the person's keys, clicks
/// and scrolls (Chrome's `DesktopSessionDurationTracker` hears window activation and user events
/// the same way). The app passes AppKit's notice names, so this package needs no AppKit. Input is
/// forwarded at most once a second: an input stamp at most a second old keeps a span to within a
/// second of Chrome's.
///
/// ```swift
/// feed = MainThreadActivityFeed(ledger: ledger, input: inputTap, becameActive: NSApplication.didBecomeActiveNotification,
///                               resignedActive: NSApplication.didResignActiveNotification, isActive: NSApp.isActive)
/// ```
@MainActor
public final class MainThreadActivityFeed {
    /// The shortest gap between two inputs forwarded to the ledger.
    public static let inputStrideNanos: UInt64 = 1_000_000_000

    private let ledger: MainThreadReportLedger
    private var observations: [MainActorObservation] = []
    private var subscription: InputSubscription?
    /// The last input stamp forwarded (uptime nanoseconds).
    private var lastForwardedNanos: UInt64?

    /// Starts feeding `ledger`; it stops when this is released.
    ///
    /// - Parameters:
    ///   - ledger: The ledger the next report reads.
    ///   - input: The app's input tap.
    ///   - becameActive: `NSApplication.didBecomeActiveNotification`.
    ///   - resignedActive: `NSApplication.didResignActiveNotification`.
    ///   - isActive: Whether the app is active now (a span starts at once).
    ///   - center: Where the notices are posted (tests pass their own).
    public init(ledger: MainThreadReportLedger, input: any InputObserving, becameActive: Notification.Name,
                resignedActive: Notification.Name, isActive: Bool, center: NotificationCenter = .default) {
        self.ledger = ledger
        if isActive { ledger.didBecomeActive() }
        observations = [
            MainActorObservation(becameActive, center: center) { ledger.didBecomeActive() },
            MainActorObservation(resignedActive, center: center) { ledger.didResignActive() },
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

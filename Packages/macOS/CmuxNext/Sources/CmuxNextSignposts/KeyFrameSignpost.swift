public import Foundation

/// The always-on `key.frame` interval (``SignpostName/keyToFrame``): from the app dispatching a key-down to the end
/// of the Core Animation commit that ends that turn (the boundary ``CommitBoundary`` uses).
///
/// Message: `target=<view|terminal> age_ms=<age>`, the key's age when its dispatch began (its wait in the event
/// queue), so a reader adds that wait to the interval. For a text view (the Home composer, the omnibar, a field) the
/// commit carries the typed character; for a terminal it carries the key's own work only, and the echo comes back
/// from the shell in a later frame, so `target=terminal` rows are the main thread's share of the key.
///
/// It runs on every key-down of the process, in Release, so a key builds no `String` and makes no observer: the
/// message fields go to the log system unformatted (``Signposter/begin(_:keyTarget:ageMilliseconds:)``), and the
/// intervals end from one main run-loop observer, installed at the first key and kept. That observer sits where
/// ``CommitBoundary`` does (one after Core Animation's commit order, before waiting and on exit) and ends only the
/// intervals pending then. A key begun after its before-waiting callout ran ends at the wake as
/// ``CommitBoundary/Outcome/missed``, like a ``CommitBoundary`` asked for at that point.
///
/// The application object makes one and keeps it:
///
/// ```swift
/// private let keyFrames = KeyFrameSignpost()
/// keyFrames.begin(target: .view, eventTimestamp: event.timestamp)
/// ```
@MainActor
public final class KeyFrameSignpost {
    /// What has the keyboard when the key is dispatched.
    public enum Target: String, Sendable {
        /// A text view or any view that is not a terminal: the commit shows the typed character.
        case view
        /// A terminal: the commit shows the key's own work; the echo is a later frame.
        case terminal
    }

    private let signposter: Signposter
    /// Intervals of keys begun whose turn has not ended yet, in begin order.
    private var pending: [SignpostInterval] = []
    private var isInstalled = false

    /// A key-frame signposter on ``Signposter/key``. It installs its run-loop observer at the first key.
    public convenience init() {
        self.init(signposter: .key)
    }

    /// - Parameter signposter: A ``SignpostCategory/key`` signposter (tests pass one with their own MetricKit mirror).
    init(signposter: Signposter) {
        self.signposter = signposter
    }

    /// Keys begun whose interval has not ended yet (tests).
    var pendingCount: Int { pending.count }

    /// Begins the interval for a key-down dispatched now; it ends after this main run-loop turn's commit.
    ///
    /// - Parameters:
    ///   - target: What has the keyboard.
    ///   - eventTimestamp: The key event's timestamp (seconds since boot, `NSEvent.timestamp`); 0 records age -1.
    ///   - now: Seconds since boot now (`ProcessInfo.systemUptime`, the event timestamp's clock).
    public func begin(target: Target, eventTimestamp: TimeInterval, // perf-hot: 0.01ms key-dispatch (every key-down of the process)
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard signposter.isEnabled else { return }
        if !isInstalled { install() }
        let age = eventTimestamp > 0 ? max(0, now - eventTimestamp) * 1000 : -1
        pending.append(signposter.begin(.keyToFrame, keyTarget: target.rawValue, ageMilliseconds: age))
    }

    /// Installs the one observer that ends the pending intervals at each turn's commit. It stays for this object's
    /// lifetime; after that, its next callout invalidates it.
    private func install() {
        isInstalled = true
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CommitBoundary.order) {
            [weak self] observer, activity in
            let outcome: CommitBoundary.Outcome = activity == .afterWaiting ? .missed : .committed
            // main-proof: the observer is added to the main run loop only (below).
            let isOwned = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                self.turnEnded(outcome)
                return true
            }
            if !isOwned, let observer { CFRunLoopObserverInvalidate(observer) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    /// Ends every pending interval with `outcome`.
    private func turnEnded(_ outcome: CommitBoundary.Outcome) {
        guard !pending.isEmpty else { return }
        for interval in pending { signposter.end(.keyToFrame, interval, outcome) }
        pending.removeAll(keepingCapacity: true)
    }
}

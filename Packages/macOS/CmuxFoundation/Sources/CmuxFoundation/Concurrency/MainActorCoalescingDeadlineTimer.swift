import Foundation

/// Owns the dispatch source independently of main-actor isolation.
///
/// Dispatch sources support thread-safe cancellation, but older Swift 6
/// compilers do not model `DispatchSourceTimer` as `Sendable`. Keeping cleanup
/// in this deliberately unchecked owner lets the main-actor timer remain
/// isolated while its nonisolated destruction safely releases the source.
private final class MainActorCoalescingTimerStorage: @unchecked Sendable {
    let timer: any DispatchSourceTimer

    init(timer: any DispatchSourceTimer) {
        self.timer = timer
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}

/// Coalesces a hot stream of main-actor deadline updates onto one timer handle.
///
/// The action and weak owner are installed once. Rescheduling only updates the
/// existing timer's deadline, so repeated signals allocate neither tasks nor
/// replacement closures.
@MainActor
public final class MainActorCoalescingDeadlineTimer<Owner: AnyObject> {
    private weak var owner: Owner?
    private let action: @MainActor (Owner) -> Void
    private let timerStorage: MainActorCoalescingTimerStorage
    private var scheduledDeadlineUptimeNanoseconds: UInt64?

    private var timer: any DispatchSourceTimer {
        timerStorage.timer
    }

    /// Creates a reusable deadline timer for `owner`.
    ///
    /// The timer retains `action` but holds `owner` weakly.
    ///
    /// - Parameters:
    ///   - owner: The object that receives the coalesced action.
    ///   - action: Main-actor work to invoke with a live owner.
    public init(
        owner: Owner,
        action: @escaping @MainActor (Owner) -> Void
    ) {
        self.owner = owner
        self.action = action

        // A reusable dispatch timer is intentional here: this synchronous hot
        // path has no async context to host a clock sleep without one Task per event.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timerStorage = MainActorCoalescingTimerStorage(timer: timer)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.fireIfCurrentDeadlinePassed()
            }
        }
        timer.resume()
    }

    /// Whether the timer currently has an armed deadline.
    public var isScheduled: Bool {
        scheduledDeadlineUptimeNanoseconds != nil
    }

    /// Replaces the current deadline with one `delay` from now.
    ///
    /// - Parameter delay: The intended delay, clamped to zero.
    public func schedule(after delay: Duration) {
        let deadline = DispatchTime.now() + dispatchInterval(for: delay)
        scheduledDeadlineUptimeNanoseconds = deadline.uptimeNanoseconds
        timer.schedule(deadline: deadline)
    }

    /// Disarms the current deadline without destroying the timer handle.
    public func cancel() {
        scheduledDeadlineUptimeNanoseconds = nil
        timer.schedule(deadline: .distantFuture)
    }

    private func fireIfCurrentDeadlinePassed() {
        guard let scheduledDeadlineUptimeNanoseconds,
              DispatchTime.now().uptimeNanoseconds >= scheduledDeadlineUptimeNanoseconds else {
            return
        }

        self.scheduledDeadlineUptimeNanoseconds = nil
        timer.schedule(deadline: .distantFuture)
        guard let owner else { return }
        action(owner)
    }

    private func dispatchInterval(for delay: Duration) -> DispatchTimeInterval {
        let components = max(delay, .zero).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let nanoseconds = min(
            (seconds * 1_000_000_000).rounded(.up),
            9_000_000_000_000_000_000
        )
        return .nanoseconds(Int(nanoseconds))
    }
}

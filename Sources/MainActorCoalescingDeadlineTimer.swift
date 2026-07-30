import Foundation

/// Coalesces a hot stream of main-actor deadline updates onto one timer handle.
///
/// The action and weak owner are installed once. Rescheduling only updates the
/// existing timer's deadline, so repeated signals allocate neither tasks nor
/// replacement closures.
@MainActor
final class MainActorCoalescingDeadlineTimer<Owner: AnyObject> {
    private weak var owner: Owner?
    private let action: @MainActor (Owner) -> Void
    private let timer: DispatchSourceTimer
    private var scheduledDeadlineUptimeNanoseconds: UInt64?

    init(
        owner: Owner,
        action: @escaping @MainActor (Owner) -> Void
    ) {
        self.owner = owner
        self.action = action

        // A reusable dispatch timer is intentional here: this synchronous hot
        // path has no async context to host a clock sleep without one Task per event.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.fireIfCurrentDeadlinePassed()
            }
        }
        timer.resume()
    }

    var isScheduled: Bool {
        scheduledDeadlineUptimeNanoseconds != nil
    }

    func schedule(after delay: Duration) {
        let deadline = DispatchTime.now() + Self.dispatchInterval(for: delay)
        scheduledDeadlineUptimeNanoseconds = deadline.uptimeNanoseconds
        timer.schedule(deadline: deadline)
    }

    func cancel() {
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

    private static func dispatchInterval(for delay: Duration) -> DispatchTimeInterval {
        let components = max(delay, .zero).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let nanoseconds = min(
            (seconds * 1_000_000_000).rounded(.up),
            9_000_000_000_000_000_000
        )
        return .nanoseconds(Int(nanoseconds))
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}

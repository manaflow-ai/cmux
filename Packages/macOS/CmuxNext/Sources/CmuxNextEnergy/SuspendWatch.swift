internal import AppKit
public import CmuxNextWakeups
internal import Network

/// The Mac's sleep, wake and display sleep, observed once for the app: the
/// composition root's ``EnergyMonitor`` follows the app's one watch and publishes its ``State`` as
/// ``EnergyPolicy/suspended``, ``EnergyPolicy/screensAsleep`` and ``EnergyPolicy/networkResumes``.
///
/// Chrome's `PowerMonitor` reports the same suspend and resume (base/power_monitor/power_monitor.h,
/// `AddPowerSuspendObserverAndReturnSuspendedState`; on macOS from IOKit's system power callback
/// in power_monitor_device_source_mac.mm), and its network change notifier tells the sockets when
/// the network is back. Here the notices are NSWorkspace's: `willSleepNotification` and
/// `didWakeNotification` for the system, `screensDidSleepNotification` and
/// `screensDidWakeNotification` for the displays. After each wake one ``NetworkPathWait`` runs until
/// the path is satisfied and then counts one resume; nothing watches the network otherwise.
@MainActor
public final class SuspendWatch {
    /// What the watch has seen.
    public nonisolated struct State: Sendable, Equatable {
        /// Between `willSleepNotification` and `didWakeNotification`.
        public var suspended = false
        /// Between `screensDidSleepNotification` and `screensDidWakeNotification`.
        public var screensAsleep = false
        /// The wakes whose network path came back, counted from ``start()``.
        public var networkResumes: UInt64 = 0

        public init(suspended: Bool = false, screensAsleep: Bool = false, networkResumes: UInt64 = 0) {
            self.suspended = suspended
            self.screensAsleep = screensAsleep
            self.networkResumes = networkResumes
        }
    }

    /// The state now.
    public private(set) var state = State()
    /// Called with the new state after each change (the monitor, its one reader).
    var onChange: (@MainActor (State) -> Void)?

    private let events: AppEvents
    private let path: NetworkPathWait
    private var subscriptions: [EventSubscription] = []
    /// The path wait of the last wake; nil once it reported or a sleep dropped it.
    private var pathWait: NetworkPathWait.Handle?
    /// Counts wakes, so a path report of an older wake changes nothing.
    private var wakes: UInt64 = 0

    /// A watch of `events`' sleep and wake notices that waits for `path` after each wake.
    ///
    /// - Parameters:
    ///   - events: The fan-out on `NSWorkspace.shared.notificationCenter` (`AppServices.workspaceEvents`).
    ///   - path: The network path wait (``NetworkPathWait/system(on:)``; tests pass their own).
    public init(events: AppEvents, path: NetworkPathWait) {
        self.events = events
        self.path = path
    }

    /// Follows the notices; a second call does nothing.
    public func start() {
        guard subscriptions.isEmpty else { return }
        let owner = "SuspendWatch"
        subscriptions = [
            events.subscribe(NSWorkspace.willSleepNotification, owner: owner) { [weak self] in self?.willSleep() },
            events.subscribe(NSWorkspace.didWakeNotification, owner: owner) { [weak self] in self?.didWake() },
            events.subscribe(NSWorkspace.screensDidSleepNotification, owner: owner) { [weak self] in self?.setScreensAsleep(true) },
            events.subscribe(NSWorkspace.screensDidWakeNotification, owner: owner) { [weak self] in self?.setScreensAsleep(false) },
        ]
    }

    /// Stops following the notices and drops a path wait; the state stays as it was.
    public func stop() {
        subscriptions = []
        dropPathWait()
    }

    private func willSleep() {
        dropPathWait()
        update { $0.suspended = true }
    }

    private func didWake() {
        dropPathWait()
        wakes &+= 1
        let wake = wakes
        pathWait = path.start { [weak self] in self?.pathSatisfied(wake: wake) }
        update { $0.suspended = false }
    }

    private func setScreensAsleep(_ asleep: Bool) {
        update { $0.screensAsleep = asleep }
    }

    /// The path after wake `wake` is satisfied: one resume, unless a later sleep or wake came first.
    private func pathSatisfied(wake: UInt64) {
        guard wake == wakes, pathWait != nil, !state.suspended else { return }
        dropPathWait()
        update { $0.networkResumes &+= 1 }
    }

    private func dropPathWait() {
        pathWait?.cancel()
        pathWait = nil
    }

    private func update(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}

/// Waits once for a satisfied network path: the seam ``SuspendWatch`` starts after each wake.
public nonisolated struct NetworkPathWait: Sendable {
    /// One wait; ``cancel()`` stops it (a satisfied call already posted may still come; the watch ignores it).
    public nonisolated struct Handle: Sendable {
        private let stop: @Sendable () -> Void

        public init(cancel: @escaping @Sendable () -> Void) {
            stop = cancel
        }

        public func cancel() { stop() }
    }

    /// Starts a wait that calls its closure on the main actor once the path is satisfied (at once
    /// when it already is).
    public typealias Start = @MainActor @Sendable (_ satisfied: @escaping @MainActor @Sendable () -> Void) -> Handle

    let start: Start

    /// A wait that `start` begins (tests record the closure and call it).
    public init(start: @escaping Start) {
        self.start = start
    }

    /// One `NWPathMonitor` per wait on a utility queue; each satisfied report reaches the main actor
    /// as one `background` task of `mainWork`, and the watch cancels the monitor at the first.
    public static func system(on mainWork: MainWorkScheduler) -> NetworkPathWait {
        NetworkPathWait { satisfied in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                mainWork.postFromAnyThread(.background, owner: "SuspendWatch.path", satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "com.cmuxterm.next.energy.wake-path", qos: .utility))
            return Handle { monitor.cancel() }
        }
    }
}

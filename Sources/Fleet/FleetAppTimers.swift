import CmuxFleet
import Foundation

/// Schedules cancellable one-shot Fleet timers on the main queue.
@MainActor
final class FleetAppTimers: FleetTimerScheduling {
    private var timers: [String: DispatchSourceTimer] = [:]

    /// Schedules a timer and replaces any existing timer for the same key.
    func schedule(key: String, delayMS: Int, onFire: @escaping @MainActor () -> Void) {
        cancel(key: key)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(max(0, delayMS)), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.timers[key] === timer else { return }
                self.timers.removeValue(forKey: key)?.cancel()
                onFire()
            }
        }
        timers[key] = timer
        timer.resume()
    }

    /// Cancels a timer for one key.
    func cancel(key: String) {
        timers.removeValue(forKey: key)?.cancel()
    }

    /// Cancels every scheduled timer.
    func cancelAll() {
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
    }
}

/// Watches Fleet agent PIDs for process exit.
@MainActor
final class FleetAppProcessWatcher: FleetProcessWatching {
    private var watchers: [Int32: DispatchSourceProcess] = [:]
    private let queue = DispatchQueue(label: "cmux.fleet.processWatcher", qos: .utility)

    /// Starts watching one PID and replaces any prior watcher for that PID.
    func watchExit(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        guard pid > 0 else { return }
        cancel(pid: pid)
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.watchers[pid] === source else { return }
                self.watchers.removeValue(forKey: pid)?.cancel()
                onExit()
            }
        }
        watchers[pid] = source
        source.resume()
    }

    /// Cancels the watcher for one PID.
    func cancel(pid: Int32) {
        watchers.removeValue(forKey: pid)?.cancel()
    }
}

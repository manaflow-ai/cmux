// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import ApplicationServices
import Foundation

/// When to stop waiting after an action: the app went quiet for `quiet`
/// after its last accessibility notification, or `ceiling` passed. An app
/// that sends nothing at all ends after `idleFloor`. Event driven: no fixed
/// sleep, and a fast app ends the wait as soon as it has drawn.
struct SettlePolicy: Sendable, Equatable {
    var quiet: Duration = .milliseconds(40)
    var idleFloor: Duration = .milliseconds(60)
    var ceiling: Duration = .milliseconds(600)

    static let none = SettlePolicy(quiet: .zero, idleFloor: .zero, ceiling: .zero)

    /// Pure decision for a moment `now` after the action, given the time of the
    /// last notification (nil: none yet). Returns nil to keep waiting, or why it ended.
    func outcome(elapsed: Duration, sinceLastEvent: Duration?) -> SettleOutcome? {
        if elapsed >= ceiling { return .ceiling }
        if let sinceLastEvent { return sinceLastEvent >= quiet ? .quiet : nil }
        return elapsed >= idleFloor ? .idle : nil
    }
}

enum SettleOutcome: String, Sendable {
    case quiet, idle, ceiling, skipped
}

/// One AXObserver per target pid on a dedicated run loop thread; the latest
/// notification time is the only state an action reads.
final class AppActivityMonitor: @unchecked Sendable {
    static let notifications: [String] = [
        kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXUIElementDestroyedNotification,
        kAXCreatedNotification, kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification,
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMenuOpenedNotification,
        kAXMenuClosedNotification, kAXTitleChangedNotification, kAXSelectedTextChangedNotification,
        kAXRowCountChangedNotification, kAXSelectedRowsChangedNotification, kAXResizedNotification,
        kAXMovedNotification, kAXSheetCreatedNotification,
    ]

    private let lock = NSLock()
    private var lastEvent: [pid_t: ContinuousClock.Instant] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private let thread: RunLoopThread

    init() { thread = RunLoopThread(name: "cmux.cu.ax-observer") }

    /// Starts watching `pid` (idempotent). Returns false when the app refuses.
    @discardableResult
    func watch(pid: pid_t) -> Bool {
        if lock.withLock({ observers[pid] != nil }) { return true }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            Unmanaged<AppActivityMonitor>.fromOpaque(refcon).takeUnretainedValue().record(pid: pid)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        lock.withLock { observers[pid] = observer }
        let source = RunLoopSource(AXObserverGetRunLoopSource(observer))
        thread.perform { CFRunLoopAddSource(CFRunLoopGetCurrent(), source.raw, .defaultMode) }
        return true
    }

    func forget(pid: pid_t) {
        guard let observer = lock.withLock({ observers.removeValue(forKey: pid) }) else { return }
        let source = RunLoopSource(AXObserverGetRunLoopSource(observer))
        thread.perform { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source.raw, .defaultMode) }
    }

    private func record(pid: pid_t) {
        let now = ContinuousClock.now
        lock.withLock { lastEvent[pid] = now }
    }

    func lastEventTime(pid: pid_t) -> ContinuousClock.Instant? { lock.withLock { lastEvent[pid] } }

    /// Waits until `policy` says the app settled after an action at `start`.
    /// Polls the shared timestamp at 4 ms granularity; the notifications
    /// themselves arrive on the observer thread.
    func settle(pid: pid_t, since start: ContinuousClock.Instant, policy: SettlePolicy) async -> (SettleOutcome, Duration) {
        guard policy.ceiling > .zero else { return (.skipped, .zero) }
        let clock = ContinuousClock()
        while true {
            let now = clock.now
            let last = lastEventTime(pid: pid).flatMap { $0 >= start ? $0 : nil }
            if let outcome = policy.outcome(elapsed: now - start, sinceLastEvent: last.map { now - $0 }) {
                return (outcome, now - start)
            }
            try? await Task.sleep(for: .milliseconds(4), tolerance: .milliseconds(1), clock: clock)
        }
    }
}

/// A run loop source handed to the observer thread (CF sources are thread-safe to add).
struct RunLoopSource: @unchecked Sendable {
    let raw: CFRunLoopSource
    init(_ raw: CFRunLoopSource) { self.raw = raw }
}

/// A thread that runs a CFRunLoop forever, for observer sources.
final class RunLoopThread: @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A source keeps the loop alive before any observer is added.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            self.ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }
}

import Foundation

/// Detects main-actor starvation from a background timer and requests one
/// diagnostic capture per stall without asking the blocked main thread to
/// participate.
///
/// `@unchecked Sendable` is safe because mutable monitoring state is confined
/// to `monitorQueue`; `started` is main-actor isolated.
final class MainThreadHangWatchdog: @unchecked Sendable {
    private let heartbeatInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let date: @Sendable () -> Date
    private let capture: @Sendable (Date, TimeInterval) -> Void
    private let monitorQueue = DispatchQueue(
        label: "com.cmuxterm.main-thread-hang-watchdog",
        qos: .utility
    )
    private var state: MainThreadHangWatchdogState
    private var timer: DispatchSourceTimer?
    private var heartbeatQueued = false
    @MainActor private var started = false

    init(
        stallThreshold: TimeInterval = 8,
        heartbeatInterval: TimeInterval = 1,
        uptime: @escaping @Sendable () -> TimeInterval,
        date: @escaping @Sendable () -> Date,
        capture: @escaping @Sendable (Date, TimeInterval) -> Void
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.uptime = uptime
        self.date = date
        self.capture = capture
        state = MainThreadHangWatchdogState(stallThreshold: stallThreshold)
    }

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        let initialHeartbeat = uptime()

        monitorQueue.async { [self] in
            state.recordHeartbeat(at: initialHeartbeat)
            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(
                deadline: .now() + heartbeatInterval,
                repeating: heartbeatInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.activate()
            queueHeartbeat()
        }
    }

    private func tick() {
        let timestamp = uptime()
        if state.shouldCapture(at: timestamp),
           let lastHeartbeat = state.lastHeartbeat {
            capture(date(), timestamp - lastHeartbeat)
        }
        queueHeartbeat()
    }

    /// Keeps at most one heartbeat pending on the main actor. A long stall
    /// therefore does not enqueue hundreds of obsolete callbacks.
    private func queueHeartbeat() {
        guard !heartbeatQueued else { return }
        heartbeatQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let timestamp = uptime()
            monitorQueue.async { [self] in
                self.state.recordHeartbeat(at: timestamp)
                self.heartbeatQueued = false
            }
        }
    }
}

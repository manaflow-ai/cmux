import Foundation

/// One watchdog deadline for a single main-actor socket command.
///
/// Safety: mutable timer/finish state is protected by `lock`; collaborators are Sendable.
nonisolated final class MainThreadSocketCommandWatchdogTicket: @unchecked Sendable {
    private let descriptor: SocketCommandDescriptor
    private let thresholdMs: Double
    private let startNs: UInt64
    private let reporter: MainThreadSocketCommandWatchdogReporter
    private let backtraceCapturer: any SocketCommandBacktraceCapturing

    // Protects the timer/finish race between the socket worker and the
    // DispatchSource handler. The critical section is a tiny synchronous flag
    // update; an actor would add an async hop to command completion.
    private let lock = NSLock()
    // DispatchSourceTimer is used because this synchronous socket path has no
    // async task to host Clock.sleep; it is a one-shot deadline only.
    private var timer: DispatchSourceTimer?
    private var didFire = false
    private var didFinish = false
    private var isCapturingBacktrace = false
    private var isReportingHang = false
    private var pendingRecoveryElapsedMs: Double?

    init(
        descriptor: SocketCommandDescriptor,
        thresholdMs: Double,
        startNs: UInt64,
        reporter: MainThreadSocketCommandWatchdogReporter,
        backtraceCapturer: any SocketCommandBacktraceCapturing
    ) {
        self.descriptor = descriptor
        self.thresholdMs = thresholdMs
        self.startNs = startNs
        self.reporter = reporter
        self.backtraceCapturer = backtraceCapturer
    }

    func start(on queue: DispatchQueue) {
        guard thresholdMs > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(max(1, Int(thresholdMs.rounded(.up)))),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.fireIfNeeded(nowNs: DispatchTime.now().uptimeNanoseconds)
        }

        lock.lock()
        if didFinish {
            lock.unlock()
            timer.resume()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func fireIfNeeded(nowNs: UInt64) {
        let elapsedMs = Self.elapsedMs(startNs: startNs, nowNs: nowNs)
        guard elapsedMs >= thresholdMs else { return }

        lock.lock()
        guard !didFinish, !didFire, !isCapturingBacktrace else {
            lock.unlock()
            return
        }
        isCapturingBacktrace = true
        lock.unlock()

        let backtrace = backtraceCapturer.captureBacktrace()

        lock.lock()
        isCapturingBacktrace = false
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFire = true
        isReportingHang = true
        lock.unlock()

        reporter.reportHang(
            MainThreadSocketCommandWatchdogObservation(
                descriptor: descriptor,
                elapsedMs: elapsedMs,
                thresholdMs: thresholdMs,
                backtrace: backtrace
            )
        )

        lock.lock()
        isReportingHang = false
        let recoveryElapsedMs = pendingRecoveryElapsedMs
        pendingRecoveryElapsedMs = nil
        lock.unlock()

        if let recoveryElapsedMs {
            reportRecovery(elapsedMs: recoveryElapsedMs)
        }
    }

    func finish(nowNs: UInt64) {
        let elapsedMs = Self.elapsedMs(startNs: startNs, nowNs: nowNs)

        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let timer = self.timer
        self.timer = nil
        let shouldReportRecovery = didFire && !isCapturingBacktrace && !isReportingHang
        if isCapturingBacktrace || isReportingHang || (didFire && !shouldReportRecovery) {
            pendingRecoveryElapsedMs = elapsedMs
        }
        lock.unlock()

        timer?.cancel()

        if shouldReportRecovery {
            reportRecovery(elapsedMs: elapsedMs)
        }
    }

    private func reportRecovery(elapsedMs: Double) {
        reporter.reportRecovery(
            MainThreadSocketCommandWatchdogObservation(
                descriptor: descriptor,
                elapsedMs: elapsedMs,
                thresholdMs: thresholdMs,
                backtrace: []
            )
        )
    }

    private static func elapsedMs(startNs: UInt64, nowNs: UInt64) -> Double {
        guard nowNs >= startNs else { return 0 }
        return Double(nowNs - startNs) / 1_000_000
    }
}

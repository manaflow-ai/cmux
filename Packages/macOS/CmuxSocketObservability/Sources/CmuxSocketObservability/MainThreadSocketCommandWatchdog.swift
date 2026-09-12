import Foundation

/// Arms a one-shot watchdog while a socket command is executing on the main actor.
///
/// Safety: instances hold immutable Sendable collaborators and a serial timer queue.
nonisolated public final class MainThreadSocketCommandWatchdog: @unchecked Sendable {
    public static let defaultThresholdMs: Double = 1000

    let thresholdMs: Double
    private let reporter: MainThreadSocketCommandWatchdogReporter
    private let backtraceCapturer: any SocketCommandBacktraceCapturing
    // Serial timer queue for watchdog deadlines; no command work runs here.
    private let queue: DispatchQueue

    public init(
        thresholdMs: Double = defaultThresholdMs,
        reporter: any MainThreadSocketCommandWatchdogReporter,
        backtraceCapturer: any SocketCommandBacktraceCapturing = MainThreadSocketCommandBacktraceCapturer(),
        queue: DispatchQueue = DispatchQueue(
            label: "com.cmuxterm.app.socket-command-watchdog",
            qos: .utility
        )
    ) {
        self.thresholdMs = thresholdMs
        self.reporter = reporter
        self.backtraceCapturer = backtraceCapturer
        self.queue = queue
    }

    public func monitor<T>(
        descriptor: SocketCommandDescriptor,
        startNs: UInt64,
        _ body: () -> T
    ) -> T {
        guard descriptor.executedOnMain else {
            return body()
        }

        let ticket = MainThreadSocketCommandWatchdogTicket(
            descriptor: descriptor,
            thresholdMs: thresholdMs,
            startNs: startNs,
            reporter: reporter,
            backtraceCapturer: backtraceCapturer
        )
        ticket.start(on: queue)
        defer { ticket.finish(nowNs: DispatchTime.now().uptimeNanoseconds) }
        return body()
    }

}

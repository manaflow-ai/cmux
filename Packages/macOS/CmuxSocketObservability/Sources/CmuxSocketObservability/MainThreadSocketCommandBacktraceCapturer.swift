import Darwin
import Foundation

/// Captures a best-effort stack from the recorded main thread.
nonisolated public struct MainThreadSocketCommandBacktraceCapturer: SocketCommandBacktraceCapturing {
    private let mainThread: thread_act_t?

    public init() {
        self.init(mainThread: Self.currentMainThreadIfAvailable())
    }

    init(mainThread: thread_act_t?) {
        self.mainThread = mainThread
    }

    public func captureBacktrace() -> [String] {
        guard let mainThread else {
            return ["main-thread backtrace unavailable: capturer was not initialized on the main thread"]
        }
        let currentThread = pthread_mach_thread_np(pthread_self())
        if mainThread == currentThread {
            return Thread.callStackSymbols
        }

        let addresses = MachThreadStackAddressSampler.captureAddresses(
            for: mainThread,
            maxFrames: 64
        )
        guard !addresses.isEmpty else {
            return ["main-thread backtrace unavailable: unable to sample main thread stack"]
        }
        return SocketCommandBacktraceSymbolicator.symbolicate(addresses)
    }

    private static func currentMainThreadIfAvailable() -> thread_act_t? {
        guard Thread.isMainThread else { return nil }
        return pthread_mach_thread_np(pthread_self())
    }
}

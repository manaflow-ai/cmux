// DEBUG and Demo builds only (compiled out of Release): the list rig's main-thread stall watchdog.
#if DEBUG
import Darwin
import Foundation
import os

/// Logs the main thread's stack (`CMUX_MAIN_STALL`, subsystem dev.cmux.mobile, category stall,
/// and appended to `CMUX_MOBILE_STALL_LOG` when set: a host path a UI test reads and attaches)
/// each time it has not run a turn for 2 s: the watchdog thread pings the main queue, and when
/// the ping goes unanswered it signals the main thread, whose handler records its own stack.
/// A diagnostic for the list rig (`CMUX_MOBILE_STALL_WATCHDOG=1`), never a product path.
public enum MainStallWatchdog {
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "stall")
    private static let depth: Int32 = 128
    nonisolated(unsafe) private static var mainThread: pthread_t?
    nonisolated(unsafe) private static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    nonisolated(unsafe) private static var captured: Int32 = 0
    nonisolated(unsafe) private static var started = false
    private static let answered = OSAllocatedUnfairLock(initialState: true)
    private static let file = ProcessInfo.processInfo.environment["CMUX_MOBILE_STALL_LOG"]

    private static func record(_ text: String) {
        log.notice("\(text, privacy: .public)")
        guard let file else { return }
        let data = Data((text + "\n\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: file, contents: data)
        }
    }

    /// Starts once, from the main thread.
    @MainActor
    public static func start() {
        guard !started else { return }
        started = true
        mainThread = pthread_self()
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Async-signal context: only backtrace into a preallocated buffer.
            MainStallWatchdog.captured = backtrace(MainStallWatchdog.frames, MainStallWatchdog.depth)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(SIGUSR2, &action, nil)
        let thread = Thread { watch() }
        thread.name = "cmux.stall-watchdog"
        thread.start()
        record("CMUX_MAIN_STALL watchdog started")
    }

    private static func watch() {
        var stalledFor = 0.0
        while true {
            answered.withLock { $0 = false }
            DispatchQueue.main.async { answered.withLock { $0 = true } }
            Thread.sleep(forTimeInterval: 2)
            if answered.withLock({ $0 }) {
                stalledFor = 0
                continue
            }
            stalledFor += 2
            guard let mainThread else { continue }
            captured = 0
            pthread_kill(mainThread, SIGUSR2)
            Thread.sleep(forTimeInterval: 0.05)
            let count = captured
            guard count > 0, let symbols = backtrace_symbols(frames, count) else {
                record("CMUX_MAIN_STALL main thread busy \(stalledFor) s, no stack")
                continue
            }
            var lines: [String] = []
            for index in 0..<Int(count) {
                if let symbol = symbols[index] { lines.append(String(cString: symbol)) }
            }
            free(symbols)
            record("CMUX_MAIN_STALL main thread busy \(stalledFor) s:\n" + lines.joined(separator: "\n"))
        }
    }
}
#endif

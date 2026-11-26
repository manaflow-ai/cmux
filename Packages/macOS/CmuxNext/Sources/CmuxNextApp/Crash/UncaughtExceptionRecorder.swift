import CmuxNextControl
import CmuxNextCrashReporting
import Foundation
import ObjectiveC
import os

/// Records an uncaught Objective-C exception into `run.exception` beside the
/// run marker before the process ends, so the next launch's report and
/// notice name the cause (macOS's `.ips` holds only the backtrace). Installed
/// by `AppRunMarker`; the file is removed at a clean exit and at the next
/// launch after it is read.
///
/// Swift cannot catch an Objective-C exception, so this records and lets the
/// process end; it never resumes. It also keeps the main-thread throws inside
/// Swift jobs (``JobThrowLog``) that name what left an executor record dead (#44060).
nonisolated enum UncaughtExceptionRecorder {
    /// The file ``handle(_:)`` writes, the preprocessor this one chains to, the kept job throws and
    /// where a lost-executor report goes. C callbacks with no context reach it: process-wide.
    private struct State {
        var file: URL?
        var previous: objc_exception_preprocessor?
        var jobThrows = JobThrowLog()
        var send: (@Sendable (String, String, String) -> Void)?
    }
    // Short critical sections from any thread; the function pointers it holds are never mutated after install.
    private static let file = OSAllocatedUnfairLock<State>(uncheckedState: State())

    /// Sets the handler that writes into `url`, and an exception preprocessor (chained to the one it
    /// replaces) that keeps main-thread throws inside Swift jobs. No other code in the app installs
    /// an uncaught-exception handler (CEF and Ghostty do not).
    static func install(writingTo url: URL) {
        file.withLock { state in
            state.file = url
            if state.previous == nil { state.previous = objc_setExceptionPreprocessor(jobThrowPreprocessor) }
        }
        // The crash has begun (CrashReporter.uncaughtException starts the crash deadline).
        NSSetUncaughtExceptionHandler { CrashReporter.uncaughtException($0, then: UncaughtExceptionRecorder.handle) }
    }

    /// Stops recording (a clean exit).
    static func uninstall() {
        file.withLock { $0.file = nil }
    }

    /// The handler body: writes `exception` into the installed file, once.
    static func handle(_ exception: NSException) {
        guard let url = file.withLock({ state -> URL? in
            defer { state.file = nil }
            return state.file
        }) else { return }
        RecordedException(exception).write(to: url)
    }

    /// The preprocessor's body: keeps `exception` when the main thread runs a Swift job.
    static func noteThrow(_ exception: AnyObject) {
        if let thrown = JobThrow.capture(exception) { file.withLock { $0.jobThrows.note(thrown) } }
    }

    /// The preprocessor this one chains to. Not visible to tests: Swift 6.3.3 on Linux crashes loading
    /// a C function pointer result from another module.
    fileprivate static func chained() -> objc_exception_preprocessor? { file.withLock { $0.previous } }

    /// The kept job throws.
    static var jobThrows: JobThrowLog { file.withLock { $0.jobThrows } }

    /// Sends each lost-executor report through `send` too (a handled crash-report event).
    static func reportLostExecutors(through send: @escaping @Sendable (String, String, String) -> Void) {
        file.withLock { $0.send = send }
    }

    /// Names the throw that left the executor record `dead` (``JobThrowLog/reportLost(_:send:)``).
    static func reportLostExecutor(_ dead: UInt) {
        let (log, send) = file.withLock { ($0.jobThrows, $0.send) }
        log.reportLost(dead, send: send)
    }
}

/// The Objective-C runtime calls it for every exception thrown, before the throw unwinds.
private nonisolated let jobThrowPreprocessor: objc_exception_preprocessor = { exception in
    UncaughtExceptionRecorder.noteThrow(exception as AnyObject)
    return UncaughtExceptionRecorder.chained()?(exception) ?? exception
}

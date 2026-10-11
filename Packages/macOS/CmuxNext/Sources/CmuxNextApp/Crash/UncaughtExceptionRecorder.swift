import Foundation
import os

/// An Objective-C exception that ended the previous run: what the
/// `run.exception` file holds (crash-elimination class b: NSRangeException,
/// unrecognized selector). Holds the exception's name, reason and call stack
/// symbols only; the reason is AppKit's text and the frames are symbol names.
nonisolated struct RecordedException: Codable, Equatable, Sendable {
    var name: String
    var reason: String
    var frames: [String]

    /// "NSRangeException: <reason>", trimmed to one line for the notice.
    var summary: String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.isEmpty ? name : "\(name): \(line)"
        return text.count > 200 ? String(text.prefix(199)) + "…" : text
    }
}

/// Records an uncaught Objective-C exception into `run.exception` beside the
/// run marker before the process ends, so the next launch's report and
/// notice name the cause (macOS's `.ips` holds only the backtrace). Installed
/// by `AppRunMarker`; the file is removed at a clean exit and at the next
/// launch after it is read.
///
/// Swift cannot catch an Objective-C exception, so this records and lets the
/// process end; it never resumes.
nonisolated enum UncaughtExceptionRecorder {
    /// Frames kept from `callStackSymbols`.
    static let frameLimit = 64
    private static let file = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Sets the handler that writes into `url`. No other code in the app
    /// installs an uncaught-exception handler (CEF and Ghostty do not).
    static func install(writingTo url: URL) {
        file.withLock { $0 = url }
        NSSetUncaughtExceptionHandler { exception in UncaughtExceptionRecorder.handle(exception) }
    }

    /// Stops recording (a clean exit).
    static func uninstall() {
        file.withLock { $0 = nil }
    }

    /// The handler body: writes `exception` into the installed file, once.
    static func handle(_ exception: NSException) {
        guard let url = file.withLock({ state -> URL? in
            defer { state = nil }
            return state
        }) else { return }
        record(exception, to: url)
    }

    /// Encodes `exception` into `url`. Tests call it with their own folder
    /// (the installed file is process-wide, and suites run in parallel).
    static func record(_ exception: NSException, to url: URL) {
        let record = RecordedException(name: exception.name.rawValue, reason: exception.reason ?? "",
                                       frames: Array(exception.callStackSymbols.prefix(frameLimit)))
        do {
            // concurrency-allow: the process is ending; one small write of the exception record.
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
                .fault("uncaught exception record write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The record in `url`, or nil when there is none or it does not decode.
    static func read(_ url: URL) -> RecordedException? {
        // concurrency-allow: once at launch before the first window, a file of a few KB.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordedException.self, from: data)
    }
}

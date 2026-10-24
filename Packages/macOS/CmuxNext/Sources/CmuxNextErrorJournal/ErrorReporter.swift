public import Foundation
import os

/// cmux's own errors and faults: each is recorded in the error journal when it happens and logged
/// for Console.app. The one shared path for an error cmux reports.
///
/// The log store of a process that ended cannot be read by a later launch (only the current
/// process's can), so an error that reaches the journal only through the log harvest
/// (``OSLogErrorSource``) is lost when the app crashes, is force quit or loses power before the
/// next harvest. A reporter records the event into the journal (``ErrorRecording``) at once, and
/// logs the same text under ``subsystem``, which the harvest leaves out (``recordedSubsystems``),
/// so nothing counts twice. Its text is redacted (``ErrorRedactor``) before it is logged.
///
/// Make one per category from the app's journal (its composition root) and keep it:
///
/// ```swift
/// let errors = ErrorReporter(category: "app.quit", recorder: services.errorJournal.journal)
/// errors.error("quit setting write failed: \(error, privacy: .public)")
/// ```
public struct ErrorReporter: Sendable {
    /// The unified-log subsystem of reported errors (Console.app: `com.cmuxterm.app.next` prefix).
    public nonisolated static let subsystem = "com.cmuxterm.app.next.reported"
    /// The subsystems whose errors are recorded when they happen: this one and the page
    /// consoles' (``ConsoleErrorCapture/subsystem``). The log harvest reads none of them.
    public nonisolated static let recordedSubsystems: Set<String> = [subsystem, ConsoleErrorCapture.subsystem]

    /// The log category, also kept in each journal sample's context.
    public let category: String
    private let logSubsystem: String
    private let source: String
    private let recorder: any ErrorRecording
    private let logger: Logger

    /// Makes a reporter for one category of cmux's own errors (journal source `app`).
    /// - Parameters:
    ///   - category: The log category (`app.quit`, `home.cache`).
    ///   - recorder: The app's journal (its composition root makes the one journal); a test's recorder.
    public init(category: String, recorder: any ErrorRecording) {
        self.init(subsystem: Self.subsystem, category: category, source: "app", recorder: recorder)
    }

    /// Makes a reporter that logs under `subsystem` and records as `source` (the page consoles').
    init(subsystem: String, category: String, source: String, recorder: any ErrorRecording) {
        self.category = category
        logSubsystem = subsystem
        self.source = source
        self.recorder = recorder
        logger = Logger(subsystem: subsystem, category: category)
    }

    /// Reports an operation that failed (`Logger.error`).
    /// - Parameters:
    ///   - message: What failed, `Logger`-style (``ErrorReportMessage``).
    ///   - topFrame: The innermost useful frame, part of the fingerprint; nil for none.
    /// - Returns: The journal's record of it (tests await it).
    @discardableResult
    public func error(_ message: ErrorReportMessage, topFrame: String? = nil) -> Task<Void, Never> {
        report(.error, message.text, topFrame: topFrame)
    }

    /// Reports a bug the code never expected (`Logger.fault`).
    /// - Parameters:
    ///   - message: What happened, `Logger`-style (``ErrorReportMessage``).
    ///   - topFrame: The innermost useful frame, part of the fingerprint; nil for none.
    /// - Returns: The journal's record of it (tests await it).
    @discardableResult
    public func fault(_ message: ErrorReportMessage, topFrame: String? = nil) -> Task<Void, Never> {
        report(.fault, message.text, topFrame: topFrame)
    }

    /// Reports something that went wrong while the app carried on (`Logger.warning`).
    /// - Parameters:
    ///   - message: What happened, `Logger`-style (``ErrorReportMessage``).
    ///   - topFrame: The innermost useful frame, part of the fingerprint; nil for none.
    /// - Returns: The journal's record of it (tests await it).
    @discardableResult
    public func warning(_ message: ErrorReportMessage, topFrame: String? = nil) -> Task<Void, Never> {
        report(.warning, message.text, topFrame: topFrame)
    }

    private func report(_ level: ErrorLevel, _ text: String, topFrame: String?) -> Task<Void, Never> {
        let redactor = ErrorRedactor()
        let message = redactor.redact(text)
        let frame = topFrame.map { redactor.redact($0) }
        let event = ErrorEvent(source: source, level: level, message: message, topFrame: frame,
                               context: ["subsystem": logSubsystem, "category": category], date: Date())
        return report(event, logText: message + (frame.map { "\n    at " + $0 } ?? ""))
    }

    /// Logs `logText` (already redacted) and records `event`: the one path every report takes.
    func report(_ event: ErrorEvent, logText: String) -> Task<Void, Never> {
        // Redacted, so public: Console.app shows it as the journal keeps it.
        logger.log(level: event.level == .fault ? .fault : .error, "\(logText, privacy: .public)")
        let recorder = recorder
        // task-owner: one record; the journal folds it and appends it in its next batched write
        return Task { await recorder.record(event) }
    }
}

#if canImport(OSLog)
import OSLog
#endif

/// The system log ``IrxJournal`` mirrors each rendered event to. On Apple
/// platforms that is os.Logger at NOTICE level (notice persists in `log show`
/// where info does not). Linux has no unified log, so there the in-memory ring
/// and the JSONL file are the whole journal. One interface over per-OS sinks,
/// as Chromium's `base/logging.cc` picks os_log on Apple and its own sink
/// elsewhere.
struct IrxSystemLog: Sendable {
    #if canImport(OSLog)
    private let logger: Logger
    #endif

    init(subsystem: String, category: String) {
        #if canImport(OSLog)
        logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    /// `line` is already redacted and privacy-safe, so it is logged public.
    func notice(_ line: String) {
        #if canImport(OSLog)
        logger.notice("irx \(line, privacy: .public)")
        #endif
    }
}

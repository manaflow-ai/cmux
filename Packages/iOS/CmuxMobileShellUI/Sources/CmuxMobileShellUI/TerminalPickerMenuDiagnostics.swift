#if DEBUG
import Foundation
import OSLog

/// DEBUG-only events for counting terminal-picker menu evaluation and snapshot writes.
struct TerminalPickerMenuDiagnostics {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "TerminalPickerMenu"
    )
    private let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "TerminalPickerMenu"
    )

    func recordContentBuilderEvaluation(rowCount: Int) {
        logger.debug("content-builder evaluated rows=\(rowCount, privacy: .public)")
        os_signpost(
            .event,
            log: signpostLog,
            name: "ContentBuilderEvaluation",
            "rows=%{public}d",
            rowCount
        )
    }

    func recordRowsWrite(rowCount: Int, includesTitleChanges: Bool) {
        logger.debug(
            "snapshot rows write rows=\(rowCount, privacy: .public) includeTitles=\(includesTitleChanges, privacy: .public)"
        )
        os_signpost(
            .event,
            log: signpostLog,
            name: "SnapshotRowsWrite",
            "rows=%{public}d includeTitles=%{public}d",
            rowCount,
            includesTitleChanges ? 1 : 0
        )
    }
}
#endif

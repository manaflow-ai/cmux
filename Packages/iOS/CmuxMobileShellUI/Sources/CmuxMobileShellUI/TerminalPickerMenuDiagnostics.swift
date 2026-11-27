#if DEBUG
import Foundation
import OSLog

/// Counts native menu openings, independent of workspace refresh frequency.
struct TerminalPickerMenuDiagnostics {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "TerminalPickerMenu"
    )
    private let signpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
        category: "TerminalPickerMenu"
    )

    func recordPresentation(rowCount: Int) {
        logger.debug("presentation snapshot rows=\(rowCount, privacy: .public)")
        os_signpost(.event, log: signpostLog, name: "MenuPresentation", "rows=%{public}d", rowCount)
    }
}
#endif

import Foundation
import OSLog

nonisolated private let restoreFailureLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "Restore"
)

extension CMUXCLI {
    /// Records private restore diagnostics while returning a product-level error.
    func loggedRestoreError(
        stage: String,
        detail: String = "none",
        errorCode: Int32? = nil,
        message: String
    ) -> CLIError {
        let loggedErrorCode = errorCode.map { String($0) } ?? "none"
        restoreFailureLogger.error(
            "Restore failed stage=\(stage, privacy: .public) detail=\(detail, privacy: .private(mask: .hash)) errorCode=\(loggedErrorCode, privacy: .private(mask: .hash))"
        )
        return CLIError(message: message)
    }
}

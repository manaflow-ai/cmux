import Foundation
import OSLog

let workspaceCreateIdempotencyLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceCreateIdempotency"
)

extension TerminalController {
    protocol WorkspaceCreateIdempotencyPersisting: Sendable {
        func loadOperationIDs() throws -> [UUID]
        func saveOperationIDs(_ operationIDs: [UUID]) throws
    }
}

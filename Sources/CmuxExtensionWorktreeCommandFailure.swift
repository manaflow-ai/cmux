import CmuxFoundation
import Foundation

/// Describes a failed worktree command and whether destructive rollback is safe.
struct CmuxExtensionWorktreeCommandFailure: LocalizedError {
    let result: CommandResult
    let underlyingError: NSError
    let rollbackSafe: Bool

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

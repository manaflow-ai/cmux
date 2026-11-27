import Foundation

extension FileExplorerError {
    /// Maps a local filesystem error to the message the File Explorer shows.
    static func mutationError(from error: Error) -> FileExplorerError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteFileExistsError:
                return .mutationTargetExists
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .mutationPermissionDenied
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return mutationError(posixCode: Int32(nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return mutationError(posixCode: Int32(underlying.code))
        }
        return .mutationFailed
    }

    /// Maps an `errno` value from a local filesystem call.
    static func mutationError(posixCode: Int32) -> FileExplorerError {
        switch posixCode {
        case EEXIST, ENOTEMPTY:
            return .mutationTargetExists
        case EACCES, EPERM, EROFS:
            return .mutationPermissionDenied
        default:
            return .mutationFailed
        }
    }

    /// Maps the exit status of a remote (SSH or Cloud) mutation script.
    ///
    /// Both remote paths use ``SSHFileExplorerMutationCommand/alreadyExistsStatus``
    /// and ``SSHFileExplorerMutationCommand/permissionDeniedStatus``.
    static func mutationError(exitStatus: Int32) -> FileExplorerError {
        switch exitStatus {
        case SSHFileExplorerMutationCommand.alreadyExistsStatus:
            return .mutationTargetExists
        case SSHFileExplorerMutationCommand.permissionDeniedStatus:
            return .mutationPermissionDenied
        default:
            return .mutationFailed
        }
    }
}

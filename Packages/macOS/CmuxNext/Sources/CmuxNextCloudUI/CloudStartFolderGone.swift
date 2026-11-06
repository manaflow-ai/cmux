public import CmuxNextCloud
import Foundation

/// A Cloud start's folder that left this Mac after the start checked it (a worktree removed while the machine came
/// up): one plain line, never the machine's name or the copy's OS error, and no Retry, which would fail the same way.
/// Leo, 2026-11-06, on "Couldn't copy the folder to lease-lease_u_…: cannot list …: No such file or directory (os error 2)":
/// "what's this".
public nonisolated struct CloudStartFolderGone: Error, Equatable {
    /// The folder's name, as the start's card shows it.
    public let folder: String

    public init(folder: String) { self.folder = folder }

    public var message: String { CloudMoveStrings.folderGone(folder) }

    /// `failure`, unless the copy failed because `root` is no longer a folder on this Mac: then the folder is gone.
    public static func or(_ failure: any Error, root: String, folder: String) async -> any Error {
        await CloudMoveFolder.isFolder(root) ? failure : CloudStartFolderGone(folder: folder)
    }
}

public extension CloudMoveFailure {
    /// A chat start's failed copy as the composer reports it, with `retry`. A failure already in the person's words keeps
    /// them (the machine's socket did not answer: ``CloudMoveStrings/notConnected(_:)``); any other error is the copy's
    /// own, read by `text`. Wrapped as a copy error, the socket's failure showed as a Swift value (run 42157718918).
    static func copying(_ error: any Error, machine: String, retry: CloudMoveRetries.Retry, text: (any Error) -> String) -> CloudMoveFailure {
        if let failure = error as? CloudMoveFailure { return CloudMoveFailure(message: failure.message, retry: retry) }
        return CloudMoveFailure(message: CloudMoveStrings.syncFailed(machine, text(error)), retry: retry)
    }
}

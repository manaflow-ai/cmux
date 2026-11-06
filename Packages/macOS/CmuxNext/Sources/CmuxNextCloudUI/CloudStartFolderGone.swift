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

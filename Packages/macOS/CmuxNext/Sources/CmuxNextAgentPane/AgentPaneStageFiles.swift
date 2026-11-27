import CmuxNextCompat
package import CmuxNextWakeups
package import Foundation

/// A chat upload stage's file operations, each run on `work`'s files lane, never on the caller's
/// actor: a folder made, a file created, renamed or removed is a disk wait, long under agent disk
/// load (cmux-next main-thread hangs). The local, Cloud and peer stagers share them.
package enum AgentPaneStageFiles {
    /// Makes `folder` (nil: none) owner-only, with its parents, and the empty owner-only `file`.
    package static func make(_ file: URL, in folder: URL?, work: BackgroundWork) async -> Bool {
        (try? await work.run(.userBlocking, mayBlock: .files, { () throws -> Void in
            if let folder { try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            guard FileManager.checked.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        })) != nil
    }

    /// Renames `file` to `destination`, its folder made owner-only, then removes `folder`.
    package static func place(_ file: URL, at destination: URL, removing folder: URL, work: BackgroundWork) async -> Bool {
        (try? await work.run(.userBlocking, mayBlock: .files, shutdown: .blockShutdown, { () throws -> Void in
            try FileManager.checked.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.checked.moveItem(at: file, to: destination)
            try? FileManager.checked.removeItem(at: folder)
        })) != nil
    }

    /// Removes `url` (a stage's file or folder).
    package static func remove(_ url: URL, work: BackgroundWork) async {
        _ = try? await work.run(.userBlocking, mayBlock: .files) { try? FileManager.checked.removeItem(at: url) }
    }
}

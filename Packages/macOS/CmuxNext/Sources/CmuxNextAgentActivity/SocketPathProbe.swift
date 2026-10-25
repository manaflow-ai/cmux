import CmuxNextCompat
import Darwin
import Foundation

/// What a unix socket's path holds, read off the main actor: the socket file, or the folder whose
/// next change may bring it.
///
/// A feed that waits for a daemon's socket reads this before it connects: the stat, the walk up
/// a missing path and the folder's `open` can hang on a sleeping or network volume, so they never
/// run on the main actor (plans/cmux-next/threading-model.md). The feed watches the folder of
/// ``absent(folder:descriptor:)`` with a file-system source on its descriptor and reads again on
/// the folder's next change: an event, never a poll.
///
/// ```swift
/// let found = await SocketPathProbe.read(socket: socket, folder: .nearestExisting, watching: watchedDirectory)
/// switch found {
/// case .present: subscribe()
/// case .absent(let folder, let descriptor): watch(folder, descriptor)
/// }
/// ```
public nonisolated enum SocketPathProbe: Sendable, Equatable {
    /// A file is at the socket's path: connect (the connect still says whether a server listens).
    case present
    /// No file at the socket's path. `folder` is the folder to watch for it. `descriptor` is that
    /// folder opened for events (`O_EVTONLY`) and belongs to the receiver: a file-system source's
    /// cancel handler closes it, or ``close()`` does. Nil when the folder could not be opened, or
    /// when it is the folder the caller already watches (it is not opened again).
    case absent(folder: String, descriptor: Int32?)

    /// The folder an absent socket is waited for in.
    public nonisolated enum Folder: Sendable {
        /// The socket's own folder (a missing folder opens nothing).
        case parent
        /// The deepest existing folder on the socket's path (`/` at worst): a socket whose folder
        /// is not made yet is waited for in the folder it will be made in.
        case nearestExisting
    }

    /// Reads `socket`'s path on the cooperative pool, never on the caller's actor.
    ///
    /// - Parameters:
    ///   - socket: The socket's path.
    ///   - folder: Which folder to wait in when no file is at `socket`.
    ///   - watching: The folder the caller watches now (nil: none). When the folder to wait in is
    ///     this one, it is not opened again and the result has no descriptor.
    /// - Returns: ``present``, or ``absent(folder:descriptor:)`` with the folder to watch.
    @concurrent public static func read(socket: String, folder: Folder, watching: String?) async -> SocketPathProbe {
        let files = FileManager.checked
        if files.fileExists(atPath: socket) { return .present }
        var directory = (socket as NSString).deletingLastPathComponent
        if folder == .nearestExisting {
            while !files.fileExists(atPath: directory), directory != "/" {
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        guard directory != watching else { return .absent(folder: directory, descriptor: nil) }
        let descriptor = open(directory, O_EVTONLY)
        return .absent(folder: directory, descriptor: descriptor >= 0 ? descriptor : nil)
    }

    /// Closes the descriptor of an ``absent(folder:descriptor:)`` that the receiver does not watch
    /// (a probe that a newer one replaced, or a folder already watched). Nothing for ``present``.
    public func close() {
        if case .absent(_, let descriptor?) = self { Darwin.close(descriptor) }
    }
}

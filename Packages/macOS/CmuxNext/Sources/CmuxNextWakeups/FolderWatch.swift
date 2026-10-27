import Foundation

/// One armed set of folder watches and the stream their events go to.
struct FolderWatch {
    /// One file-system event: the watched folder it came from and what happened to that folder.
    struct Event: Sendable {
        let path: String
        /// `DispatchSource.FileSystemEvent`'s raw value (the option set is not `Sendable` everywhere); on
        /// Linux the inotify mask mapped to it (FolderWatch+Inotify.swift).
        let flagBits: UInt

        var flags: DispatchSource.FileSystemEvent { DispatchSource.FileSystemEvent(rawValue: flagBits) }
    }

    /// The folders watched (each target's nearest existing folder).
    let paths: Set<String>
    let events: AsyncStream<Event>
    /// A vnode source per folder on Darwin; the one inotify read source on Linux.
    let sources: [any DispatchSourceProtocol]
    let finish: @Sendable () -> Void

    func cancel() {
        for source in sources { source.cancel() }
        finish()
    }
}

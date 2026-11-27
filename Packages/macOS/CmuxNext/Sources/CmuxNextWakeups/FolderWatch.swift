import Foundation

/// One armed set of folder watches and the stream their events go to.
struct FolderWatch {
    /// One file-system event: the watched folder it came from and what happened to that folder.
    struct Event: Sendable {
        let path: String
        /// `DispatchSource.FileSystemEvent`'s raw value (the option set is not `Sendable` everywhere).
        let flagBits: UInt

        var flags: DispatchSource.FileSystemEvent { DispatchSource.FileSystemEvent(rawValue: flagBits) }
    }

    /// The folders watched (each target's nearest existing folder).
    let paths: Set<String>
    let events: AsyncStream<Event>
    let sources: [any DispatchSourceFileSystemObject]
    let finish: @Sendable () -> Void

    func cancel() {
        for source in sources { source.cancel() }
        finish()
    }
}

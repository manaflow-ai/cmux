import Foundation

/// One armed set of folder watches and the stream their events go to.
struct FolderWatch {
    let events: AsyncStream<Void>
    let sources: [any DispatchSourceFileSystemObject]
    let finish: @Sendable () -> Void

    func cancel() {
        for source in sources { source.cancel() }
        finish()
    }
}

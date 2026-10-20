import CoreServices
import Foundation

/// The FSEvents callback's target: turns one callback's arrays into
/// ``DirectoryWatcherEvent`` values and yields them. Immutable: the
/// continuation is `Sendable`, so the sink is too.
nonisolated final class DirectoryWatcherSink: Sendable {
    let continuation: AsyncStream<[DirectoryWatcherEvent]>.Continuation

    init(continuation: AsyncStream<[DirectoryWatcherEvent]>.Continuation) {
        self.continuation = continuation
    }

    /// Flags after which a folder must be listed again: FSEvents dropped or coalesced detail.
    private static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)

    /// The C callback FSEvents calls (on the watcher's queue).
    static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let sink = Unmanaged<DirectoryWatcherSink>.fromOpaque(info).takeUnretainedValue()
        let names = unsafeBitCast(paths, to: NSArray.self)
        var events: [DirectoryWatcherEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = names[index] as? String else { continue }
            let flag = flags[index]
            events.append(DirectoryWatcherEvent(
                path: path,
                isDirectory: flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                mustRescan: flag & rescanFlags != 0))
        }
        if !events.isEmpty { sink.continuation.yield(events) }
    }
}

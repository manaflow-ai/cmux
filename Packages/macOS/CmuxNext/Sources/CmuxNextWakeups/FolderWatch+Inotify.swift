#if os(Linux)
import Foundation
import Glibc

/// The Linux watch of ``FolderChanges``: one non-blocking inotify descriptor for all the folders, read by a
/// dispatch read source when the kernel queues an event (libdispatch waits for it in epoll), so nothing polls.
/// Each inotify event becomes the `DispatchSource.FileSystemEvent` a Darwin vnode source reports:
/// - an entry made, removed or moved in or out (`IN_CREATE`, `IN_DELETE`, `IN_MOVED_*`): `.write`;
/// - the folder itself removed or unmounted (`IN_DELETE_SELF`, `IN_UNMOUNT`): `.delete`;
/// - the folder itself moved (`IN_MOVE_SELF`), or the kernel's queue overflowed and events were lost
///   (`IN_Q_OVERFLOW`): `.rename`, so ``FolderChanges`` arms again and its consumer re-reads.
extension FolderWatch {
    static func inotify(_ paths: Set<String>) -> FolderWatch {
        let (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return FolderWatch(paths: paths, events: events, sources: [], finish: { continuation.finish() }) }
        let mask = UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
        var folders: [Int32: String] = [:]
        for folder in paths.sorted() {
            // SAFETY: inotify_add_watch reads `folder` as a C string Swift keeps alive for the call.
            let watch = unsafe inotify_add_watch(fd, folder, mask)
            if watch >= 0 { folders[watch] = folder }
        }
        let watched = folders
        let anyFolder = paths.sorted().first ?? "/"
        // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler {
            for event in InotifyEvent.readAll(fd) {
                guard let flags = event.fileSystemEvent else { continue }
                // An overflow names no watch (-1): it may have hidden a change in any folder.
                let path = event.watch == -1 ? anyFolder : watched[event.watch]
                if let path { continuation.yield(Event(path: path, flagBits: flags.rawValue)) }
            }
        }
        // The cancel handler runs after the last event handler, so the descriptor outlives every read.
        source.setCancelHandler { close(fd) }
        source.resume()
        return FolderWatch(paths: paths, events: events, sources: [source], finish: { continuation.finish() })
    }
}

/// One `struct inotify_event` as read from an inotify descriptor.
struct InotifyEvent: Equatable {
    var watch: Int32
    var mask: UInt32

    /// The event as a vnode source would report it; nil for one a vnode source has no counterpart for
    /// (`IN_IGNORED`, which follows the removal it already reported).
    var fileSystemEvent: DispatchSource.FileSystemEvent? {
        if mask & UInt32(IN_Q_OVERFLOW | IN_MOVE_SELF) != 0 { return .rename }
        if mask & UInt32(IN_DELETE_SELF | IN_UNMOUNT) != 0 { return .delete }
        if mask & UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO) != 0 { return .write }
        return nil
    }

    /// Every event queued on the non-blocking descriptor `fd`, until it would block.
    static func readAll(_ fd: Int32) -> [InotifyEvent] {
        // Room for many events: one is 16 bytes plus its name, at most NAME_MAX + 1.
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var events: [InotifyEvent] = []
        while true {
            // SAFETY: read writes at most buffer.count bytes into `buffer`, a local array of that size.
            let count = unsafe read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return events }
            events += parse(buffer.prefix(count))
        }
    }

    /// The events in `bytes`, whole `struct inotify_event` records as the kernel writes them (it never
    /// splits one across reads).
    static func parse(_ bytes: ArraySlice<UInt8>) -> [InotifyEvent] {
        // { int wd; uint32_t mask; uint32_t cookie; uint32_t len; char name[len]; } in host byte order.
        func word(_ offset: Int) -> UInt32 {
            let base = bytes.startIndex + offset
            let littleEndian = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[base + $1]) << (8 * $1) }
            return UInt32(littleEndian: littleEndian)
        }
        var events: [InotifyEvent] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            events.append(InotifyEvent(watch: Int32(bitPattern: word(offset)), mask: word(offset + 4)))
            offset += 16 + Int(word(offset + 12))
        }
        return events
    }
}
#endif

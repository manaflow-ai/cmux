#if !canImport(Darwin)
import CmuxNextCompat
import Foundation

/// One non-blocking inotify watch on a history database's folder, read by a dispatch read source when the kernel
/// queues an event (libdispatch waits in epoll), so nothing polls. A change to the database, its `-wal` or its
/// `-journal` (written, made, removed or moved), an overflow of the kernel's queue, or the folder itself going
/// calls `onChange`; other files in the folder (Preferences, Cookies) do not. Watching the folder, not the
/// files, also sees a file the browser replaces or a `-wal` made later. Linux has no security scope: `scope`
/// is not used.
final class HistoryFileWatch: Sendable {
    let file: URL
    private let onChange: @Sendable () -> Void
    /// The read source; nil once cancelled.
    private let source = Mutex<(any DispatchSourceRead)?>(nil)

    init(file: URL, scope: URL?, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.onChange = onChange
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return }
        let mask = UInt32(IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO
            | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
        // SAFETY: inotify_add_watch reads the folder path as a C string Swift keeps alive for the call.
        guard unsafe inotify_add_watch(fd, file.deletingLastPathComponent().path, mask) >= 0 else {
            close(fd)
            return
        }
        let names: Set<String> = [file.lastPathComponent, file.lastPathComponent + "-wal", file.lastPathComponent + "-journal"]
        // The source is made inside the lock: corelibs' sources are not Sendable, so it is born in the stored value.
        source.withLock { stored in
            // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            // wakeup-allow: inotify file event (no timer); the sync coalesces reads behind a DemandTimer
            reader.setEventHandler {
                if HistoryInotifyEvent.readAll(fd).contains(where: { $0.concerns(names) }) { onChange() }
            }
            // The cancel handler runs after the last event handler, so the descriptor outlives every read.
            reader.setCancelHandler { close(fd) }
            reader.resume()
            stored = reader
        }
    }

    deinit {
        cancel()
    }

    /// Stops the watch; later calls do nothing.
    func cancel() {
        source.withLock { source in defer { source = nil }; return source }?.cancel()
    }
}

/// One `struct inotify_event` read from an inotify descriptor: its mask and the entry it names.
struct HistoryInotifyEvent: Equatable {
    var mask: UInt32
    var name: String

    /// Whether ``HistoryFileWatch`` reports it: an event on one of `names`, a lost-events overflow, or the folder
    /// itself removed or moved (no name).
    func concerns(_ names: Set<String>) -> Bool {
        if mask & UInt32(IN_Q_OVERFLOW | IN_DELETE_SELF | IN_MOVE_SELF) != 0 { return true }
        return names.contains(name)
    }

    /// Every event queued on the non-blocking descriptor `fd`, until it would block.
    static func readAll(_ fd: Int32) -> [HistoryInotifyEvent] {
        // Room for many events: one is 16 bytes plus its name, at most NAME_MAX + 1.
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var events: [HistoryInotifyEvent] = []
        while true { // wakeup-allow: drains the queued events, ends when read would block
            // SAFETY: read writes at most buffer.count bytes into `buffer`, a local array of that size.
            let count = unsafe read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return events }
            events += parse(buffer.prefix(count))
        }
    }

    /// The events in `bytes`, whole `struct inotify_event` records as the kernel writes them (it never splits one
    /// across reads): `{ int wd; uint32_t mask; uint32_t cookie; uint32_t len; char name[len]; }` in host byte
    /// order, the name NUL-padded. A record that runs past `bytes` ends the parse.
    static func parse(_ bytes: ArraySlice<UInt8>) -> [HistoryInotifyEvent] {
        func word(_ offset: Int) -> UInt32 {
            let base = bytes.startIndex + offset
            return UInt32(littleEndian: (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[base + $1]) << (8 * $1) })
        }
        var events: [HistoryInotifyEvent] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            let length = Int(word(offset + 12))
            guard length <= bytes.count - offset - 16 else { break }
            let start = bytes.startIndex + offset + 16
            let name = bytes[start..<(start + length)].prefix { $0 != 0 }
            events.append(HistoryInotifyEvent(mask: word(offset + 4), name: String(decoding: name, as: UTF8.self)))
            offset += 16 + length
        }
        return events
    }
}
#endif

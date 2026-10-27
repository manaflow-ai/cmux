#if os(Linux)
import Foundation
import Glibc

/// The inotify watch behind one ``FolderWatcher`` stream on Linux, as Chromium's
/// file_path_watcher_inotify.cc: one non-blocking inotify descriptor on the folder, read when the
/// kernel has events. inotify reports only direct children, by name. A queue overflow, or the
/// folder itself removed, moved or unmounted, becomes ``FolderChange/rescan``. Each read drains
/// every queued event into one change, so a burst reaches the model as one update; `latency`
/// (FSEvents' coalescing) has no inotify counterpart. The stream's termination handler
/// (``FolderWatcher/changes(in:)``) owns it until `stop()` has run.
// crash-allow: `source` changes only on the serial `queue` (start, stop, and the read handler there); the rest is immutable
final class FolderWatchStream: @unchecked Sendable {
    private let folderPath: String
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.inotify", qos: .userInitiated)
    private var source: (any DispatchSourceRead)?

    init(folder: URL, latency: TimeInterval, continuation: AsyncStream<FolderChange>.Continuation) {
        self.folderPath = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
        self.continuation = continuation
    }

    /// The events a watch asks for: every change to a direct child, and the folder itself going away.
    static let mask = UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY | IN_ATTRIB
        | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)

    /// The events after which the watch cannot say which children changed.
    static let rescanMask = UInt32(IN_Q_OVERFLOW | IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT)

    func start() {
        queue.async { [self] in
            let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
            guard fd >= 0 else { continuation.finish(); return }
            // SAFETY: inotify_add_watch reads the NUL-terminated copy of the path made for the call.
            guard unsafe inotify_add_watch(fd, folderPath, Self.mask) >= 0 else {
                close(fd)
                continuation.finish()
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(fd) }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            // Cancelled on its own queue, the source runs no handler after this; its cancel handler closes the descriptor.
            source?.cancel()
            source = nil
        }
    }

    /// Reads every queued event (the descriptor is non-blocking: a read with nothing queued ends the drain).
    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var names: [String] = []
        var rescan = false
        var count = 0
        repeat {
            // SAFETY: read writes at most bytes.count bytes into the array's own storage, lent for the call.
            count = unsafe buffer.withUnsafeMutableBytes { bytes in unsafe read(fd, bytes.baseAddress, bytes.count) }
            if count > 0 {
                let batch = Self.parse(buffer, count: count)
                names += batch.names
                rescan = rescan || batch.rescan
            }
        } while count > 0
        var seen: Set<String> = []
        let items = names.filter { seen.insert($0).inserted }
        guard rescan || !items.isEmpty else { return }
        // A full buffer drops its oldest change; the rescan after it covers whatever was lost.
        if case .dropped = continuation.yield(rescan ? .rescan : .items(items)) { continuation.yield(.rescan) }
    }

    /// The child names and the rescan flag of one read: `count` bytes of `struct inotify_event` records
    /// (wd, mask, cookie, len, then `len` bytes of NUL-padded name). A record that runs past the read
    /// ends the batch as a rescan.
    static func parse(_ bytes: [UInt8], count: Int) -> (names: [String], rescan: Bool) {
        let header = 16
        var names: [String] = []
        var rescan = false
        var offset = 0
        while offset < count {
            guard count - offset >= header else { return (names, true) }
            let mask = word(bytes, at: offset + 4)
            let length = Int(word(bytes, at: offset + 12))
            guard length <= count - offset - header else { return (names, true) }
            if mask & rescanMask != 0 {
                rescan = true
            } else if length > 0 {
                let name = bytes[(offset + header)..<(offset + header + length)].prefix { $0 != 0 }
                if !name.isEmpty { names.append(String(decoding: name, as: UTF8.self)) }
            }
            offset += header + length
        }
        return (names, rescan)
    }

    /// The host-order `UInt32` at `offset` (the kernel writes the records in host order); the caller
    /// checked that the four bytes lie inside `bytes`.
    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        // SAFETY: offset + 4 <= bytes.count (parse checks the header before reading it); the load copies the four
        // bytes out of the array's storage, lent for the call.
        unsafe bytes.withUnsafeBytes { raw in unsafe raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
#endif

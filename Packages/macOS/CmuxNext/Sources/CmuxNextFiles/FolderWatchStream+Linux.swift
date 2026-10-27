#if os(Linux)
// swift-corelibs-libdispatch does not mark its source protocols Sendable; a dispatch source is safe to
// cancel and resume from any thread, as on Darwin, where they are.
@unsafe @preconcurrency import Dispatch
import Foundation
import Glibc

/// The inotify watch behind one ``FolderWatcher`` stream on Linux, as Chromium's
/// file_path_watcher_inotify.cc: one non-blocking inotify descriptor on the folder, read when the
/// kernel has events. inotify reports only direct children, by name. A queue overflow, or the
/// folder itself removed, moved or unmounted, becomes ``FolderChange/rescan``. Each read drains
/// every queued event into one change, so a burst reaches the model as one update; `latency`
/// (FSEvents' coalescing) has no inotify counterpart. The stream's termination handler
/// (``FolderWatcher/changes(in:)``) owns it until `stop()` has run.
///
/// Every member is immutable: the descriptor and its read source are made with the stream, the
/// watch is added and the source resumed by `start()` (exactly once) on `queue`, and `stop()`
/// cancels the source there; a source cancelled before it was resumed runs only its cancel handler.
final class FolderWatchStream: Sendable {
    private let folderPath: String
    private let continuation: AsyncStream<FolderChange>.Continuation
    private let queue = DispatchQueue(label: "cmux.files.inotify", qos: .userInitiated)
    private let descriptor: Int32
    private let source: (any DispatchSourceRead)?

    init(folder: URL, latency: TimeInterval, continuation: AsyncStream<FolderChange>.Continuation) {
        folderPath = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
        self.continuation = continuation
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        descriptor = fd
        source = fd >= 0 ? DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue) : nil
        source?.setEventHandler { [weak self] in self?.drain() }
        source?.setCancelHandler { close(fd) }
    }

    /// The events a watch asks for: every change to a direct child, and the folder itself going away.
    static let mask = UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_MODIFY | IN_ATTRIB
        | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)

    /// The events after which the watch cannot say which children changed.
    static let rescanMask = UInt32(IN_Q_OVERFLOW | IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT)

    func start() {
        guard let source else { continuation.finish(); return }
        queue.async { [self] in
            // SAFETY: inotify_add_watch reads the NUL-terminated copy of the path made for the call.
            if unsafe inotify_add_watch(descriptor, folderPath, Self.mask) < 0 {
                source.cancel()
                continuation.finish()
            }
            // Resumed once, also when cancelled: an inactive source must not be released.
            source.resume()
        }
    }

    func stop() {
        // Cancelled on its own queue, the source runs no event handler after this; its cancel handler closes the
        // descriptor.
        queue.async { [source] in source?.cancel() }
    }

    /// Reads every queued event (the descriptor is non-blocking: a read with nothing queued ends the drain).
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var names: [String] = []
        var rescan = false
        func read() -> Int {
            // SAFETY: read writes at most bytes.count bytes into the array's own storage, lent for the call.
            unsafe buffer.withUnsafeMutableBytes { bytes in unsafe Glibc.read(descriptor, bytes.baseAddress, bytes.count) }
        }
        var count = read()
        // Each pass parses one read; an empty queue (EAGAIN on the non-blocking descriptor) or an error ends it.
        while count > 0 {
            let batch = Self.parse(buffer, count: count)
            names += batch.names
            rescan = rescan || batch.rescan
            count = read()
        }
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

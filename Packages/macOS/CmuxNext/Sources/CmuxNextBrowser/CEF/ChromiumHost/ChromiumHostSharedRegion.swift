#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextSharedRegionC
import Darwin

/// A control channel payload over 64 KiB in a sealed shared memory region
/// (plans/cmux-next/chrome-parity/p01-process.md, task 020), as
/// `mojo_base::BigBuffer` (`mojo/public/cpp/base/big_buffer.h`) moves bytes
/// past its inline limit into shared memory. The C++ end is
/// `CreateSharedRegion` and `ReadSharedRegion` in
/// `ChromiumHost/src/chromium_host_control.cc`.
///
/// A sent region is the read-only descriptor of an unlinked POSIX shm object
/// whose writable descriptor is closed (`cmux_shared_region_create`): xnu
/// sizes a POSIX shm object once (`pshm_truncate` refuses a second), so
/// nobody can shrink it under the receiver's mapping. The receiver refuses
/// any descriptor that is not a read-only shm object
/// (`cmux_shared_region_is_sealed`: a regular file could be truncated under
/// the mapping), maps and copies it, and closes it. Chrome on macOS passes a
/// Mach memory entry instead (`base/memory/platform_shared_memory_region_apple.cc`);
/// this channel is a Unix socket, so it passes the shm descriptor.
nonisolated struct ChromiumHostSharedRegion: Sendable {
    /// The most bytes of one message's shared fields together: Chrome's
    /// `IPC::Channel::kMaximumMessageSize` (`ipc/ipc_channel.h`), which caps
    /// a whole message.
    static let maxBytes = 128 * 1024 * 1024

    /// The region's descriptor; the owner closes it (the outbox, once sent).
    let fd: Int32

    /// A region holding `bytes`, or nil when none can be made or `bytes` is
    /// empty or over ``maxBytes``.
    init?(holding bytes: [UInt8]) {
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes else { return nil }
        let count = bytes.count
        // SAFETY: the region copies `count` bytes, the array's size, from its buffer during the call.
        let fd = unsafe cmux_shared_region_create(bytes, count)
        guard fd >= 0 else { return nil }
        self.fd = fd
    }

    /// The first `count` bytes of the received region `fd`, or nil when it is
    /// not a read-only shm descriptor or holds fewer. Does not close `fd`.
    static func bytes(in fd: Int32, count: Int) -> [UInt8]? {
        guard count > 0, count <= maxBytes, cmux_shared_region_is_sealed(fd) != 0 else { return nil }
        var info = stat()
        // SAFETY: fstat writes one `stat` into `info` during the call.
        guard unsafe fstat(fd, &info) == 0, info.st_size >= off_t(count) else { return nil }
        // A mapping: a macOS shm descriptor has no read (xnu's pshm_read is ENOTSUP).
        // SAFETY: a read-only mapping of `count` bytes, which the sealed region holds (st_size above); it is
        // copied into the array and unmapped once, before this returns.
        guard let mapping = unsafe mmap(nil, count, PROT_READ, MAP_SHARED, fd, 0),
              unsafe mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        defer { unsafe munmap(mapping, count) }
        return unsafe [UInt8](UnsafeRawBufferPointer(start: mapping, count: count))
    }
}

/// The regions of one message's shared fields (``ChromiumHostControlMessage/sharedFieldIndices()``),
/// in field order, made on the sending thread before the channel's lock. The
/// channel's outbox owns them once the message is queued; whoever drops the
/// message before that closes them (``closeAll()``).
nonisolated struct ChromiumHostSharedPayloads: Sendable {
    private(set) var fds: [Int32] = []
    /// The payload bytes the regions hold: they count toward the outbox quota.
    private(set) var byteCount = 0

    /// One region per field at `shared` (none when it is empty); nil, with
    /// none left open, when one cannot be made.
    init?(_ message: ChromiumHostControlMessage, sharing shared: [Int]) {
        // The receiver refuses a message whose shared fields total more.
        guard message.sharedByteCount(shared) <= ChromiumHostSharedRegion.maxBytes else { return nil }
        for index in shared {
            let payload = message.payload(at: index)
            guard let region = ChromiumHostSharedRegion(holding: payload) else {
                closeAll()
                return nil
            }
            fds.append(region.fd)
            byteCount += payload.count
        }
    }

    func closeAll() {
        for fd in fds { Darwin.close(fd) }
    }
}
#endif

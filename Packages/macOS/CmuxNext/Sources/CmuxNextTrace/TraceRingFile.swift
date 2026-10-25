import CmuxNextCompat
import Darwin

/// A trace ring's `MAP_SHARED` file: the crash-safe home of a ``TraceRing`` after startup. Whatever the
/// process wrote stays in the page cache when it crashes, so the next launch or `cmux trace` decodes it.
///
/// The mapping is made once and never unmapped while the process lives, so a writer that still holds a
/// chunk in it can never fault. The blocks are allocated before the mapping is used, as Chrome's
/// `MemoryMappedFile` does for `READ_WRITE_EXTEND` (`base/files/memory_mapped_file_posix.cc`): a write
/// into a sparse page on a full disk would otherwise end the process with SIGBUS.
public final class TraceRingFile: Sendable {
    /// The ring file's path.
    public let path: String
    /// The mapped size in bytes.
    public let byteCount: Int
    /// The mapping's address (never unmapped).
    private let address: UInt

    private init(path: String, byteCount: Int, address: UInt) {
        self.path = path
        self.byteCount = byteCount
        self.address = address
    }

    /// The file name of a ring for `role` and `pid`.
    public static func fileName(role: String, pid: Int32) -> String {
        "\(role)-\(pid).cmxtrace"
    }

    /// The spare file a later launch renames instead of creating its ring file.
    public static func spareName(role: String) -> String {
        "\(role).spare.cmxtrace"
    }

    /// Moves `ring` into a new ring file in `directory`: renames the role's spare file there or creates
    /// the file, sizes and allocates it, maps it `MAP_SHARED`, points the ring's writers at it and copies
    /// the records the heap held. Blocking file work: run it on BackgroundWork `.files`, never on main.
    ///
    /// A record a thread is writing into the heap at the moment of the swap may miss the copy (at most one
    /// per thread). On any failure the ring keeps writing where it was, the failure is counted
    /// (``TraceRing/Counters/adoptFailures``) and the result is nil.
    ///
    /// - Parameters:
    ///   - ring: the ring to move.
    ///   - directory: an existing directory, or one this call may create (mode 0700).
    ///   - records: the file's capacity; nil keeps the ring's capacity.
    /// - Returns: the mapped file.
    @discardableResult
    public static func adopt(_ ring: TraceRing, directory: String, records: Int? = nil) -> TraceRingFile? {
        guard let old = ring.currentStorage else { return nil }
        let chunkCount = records.map(TraceRing.chunkCount(forRecords:)) ?? old.chunkCount
        let byteCount = TraceRing.storageBytes(chunkCount: chunkCount)
        let path = directory + "/" + fileName(role: ring.role, pid: ring.pid)
        guard let address = map(path: path, spare: directory + "/" + spareName(role: ring.role), directory: directory, byteCount: byteCount),
              let mapped = TraceRingStorage(address: address) else {
            ring.countAdoptFailure()
            return nil
        }
        mapped.writeHeader(chunkCount: chunkCount, role: ring.role, pid: ring.pid,
                           startUptimeNanos: old.startUptimeNanos, fileBacked: true)
        mapped.addCounters(from: old)
        ring.swapStorage(to: mapped)
        mapped.copyRecords(from: old)
        return TraceRingFile(path: path, byteCount: byteCount, address: address)
    }

    /// Makes the role's spare file in `directory` (empty, sized and allocated for `records` records),
    /// so the next launch's ``adopt(_:directory:records:)`` only renames it. Blocking file work.
    ///
    /// - Returns: whether the spare file is ready.
    @discardableResult
    public static func prepareSpare(directory: String, role: String, records: Int) -> Bool {
        let path = directory + "/" + spareName(role: role)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return resetAndAllocate(descriptor, byteCount: TraceRing.storageBytes(chunkCount: TraceRing.chunkCount(forRecords: records)))
    }

    /// The whole records of the ring file at `path`; nil when it cannot be read or is not a v1 ring.
    /// Blocking file work.
    public static func records(atPath path: String) -> [TraceRecord]? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Int(info.st_size) >= TraceRing.headerBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
            var done = 0
            while done < buffer.count {
                let count = blockingRead(descriptor, buffer.baseAddress.map { $0 + done }, buffer.count - done)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                done += count
            }
            return true
        }
        return complete ? TraceRing.records(inImage: bytes) : nil
    }

    /// The decoded records of this file's mapping (the ring's records while it writes here).
    public func records() -> [TraceRecord] {
        guard let base = UnsafeMutableRawPointer(bitPattern: address),
              let storage = TraceRingStorage(validating: base, byteCount: byteCount) else { return [] }
        return storage.decode()
    }

    /// Opens (renaming the spare when there is one) or creates `path`, resets and allocates it, and maps
    /// it. Returns the mapping's address, or nil after removing a file it created.
    private static func map(path: String, spare: String, directory: String, byteCount: Int) -> UInt? {
        if mkdir(directory, 0o700) != 0, errno != EEXIST { return nil }
        let renamed = rename(spare, path) == 0
        let descriptor = open(path, O_RDWR | O_CLOEXEC | (renamed ? 0 : O_CREAT | O_TRUNC), 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard resetAndAllocate(descriptor, byteCount: byteCount) else {
            unlink(path)
            return nil
        }
        let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else {
            unlink(path)
            return nil
        }
        return UInt(bitPattern: mapping)
    }

    /// Empties the file (a renamed spare may hold an old ring), then gives it `byteCount` zero bytes with
    /// their blocks allocated: `F_PREALLOCATE`, or, on a file system without it, one written zero byte per
    /// 4 KiB block, as Chrome's `MemoryMappedFile` does on macOS.
    private static func resetAndAllocate(_ descriptor: Int32, byteCount: Int) -> Bool {
        guard ftruncate(descriptor, 0) == 0 else { return false }
        var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0,
                             fst_length: off_t(byteCount), fst_bytesalloc: 0)
        let preallocated = fcntl(descriptor, F_PREALLOCATE, &store) != -1
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else { return false }
        if preallocated { return true }
        var zero: UInt8 = 0
        for offset in stride(from: 0, to: byteCount, by: 4096) where pwrite(descriptor, &zero, 1, off_t(offset)) != 1 {
            return false
        }
        return true
    }
}

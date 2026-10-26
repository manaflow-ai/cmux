import CmuxNextCompat
import Darwin

/// A trace ring's `MAP_SHARED` black-box file: the crash-safe home of a ``TraceRing`` after startup.
/// Whatever the process wrote stays in the page cache when it crashes, so the next launch or `cmux trace`
/// decodes it.
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

    /// The black-box file name of `role` in process `pid` (the Rust crate's `blackbox_file_name`).
    public static func fileName(role: TraceRing.Role, pid: UInt32) -> String {
        "\(role.fileStem)-\(pid).blackbox.cmxtrace"
    }

    /// The spare file a later launch renames instead of creating its black-box file.
    public static func spareName(role: TraceRing.Role) -> String {
        "\(role.fileStem).spare.cmxtrace"
    }

    /// Moves `ring` from the heap into its black-box file in `directory` (trace.md "Heap, then file"). It
    /// copies first and swaps last, so no writer claims a file chunk before the copy is done:
    ///
    /// 1. Renames the role's spare file or creates the file (same layout as the heap), and maps it
    ///    `MAP_SHARED`. No writer can see it yet.
    /// 2. Copies the heap's header, chunks and table entries into it with the decode protocol.
    /// 3. Stores `heap_cursor` = the copied cursor and the file's cursor one lap past it, so every new
    ///    claim is a lap past every copied chunk and overwrites the oldest copied chunks first.
    /// 4. Swaps the active ring to the file, then stores `heap_chunks_lost`.
    ///
    /// Records written to the heap between the copy and the swap are lost (``TraceRing/Counters/heapChunksLost``
    /// counts the chunks claimed in that window). Blocking file work: run it on BackgroundWork `.files`,
    /// never on main. Adoption is one-shot: a second call, or one while another runs, returns nil and is
    /// counted, and never touches the mapped file. On a failure the ring keeps writing to the heap, the
    /// failure is counted (``TraceRing/Counters/adoptFailures``) and the result is nil.
    ///
    /// - Parameters:
    ///   - ring: the ring to move.
    ///   - directory: an existing directory, or one this call may create (mode 0700).
    /// - Returns: the mapped file.
    @discardableResult
    public static func adopt(_ ring: TraceRing, directory: String) -> TraceRingFile? {
        guard ring.beginAdoption() else {
            ring.countAdoptFailure()
            return nil
        }
        guard let heap = ring.activeRing?.pointee.storage else {
            ring.endAdoption(adopted: false)
            return nil
        }
        let layout = heap.layout
        let path = directory + "/" + fileName(role: ring.identity.role, pid: ring.identity.pid)
        let spare = directory + "/" + spareName(role: ring.identity.role)
        guard let mapping = map(path: path, spare: spare, directory: directory, byteCount: layout.totalBytes) else {
            ring.countAdoptFailure()
            ring.endAdoption(adopted: false)
            return nil
        }
        let file = TraceRingStorage(base: mapping, layout: layout)
        let copied = heap.copy(into: file)
        file.word(TraceRingOffsets.heapCursor).store(copied, ordering: .relaxed)
        file.word(TraceRingOffsets.chunkCursor).store(copied &+ UInt64(layout.chunkCount), ordering: .relaxed)
        ring.activateFile(file)
        let lost = heap.counter(TraceRingOffsets.chunkCursor) &- copied
        file.word(TraceRingOffsets.heapChunksLostWord).store(min(lost, UInt64(UInt32.max)), ordering: .relaxed)
        ring.endAdoption(adopted: true)
        return TraceRingFile(path: path, byteCount: layout.totalBytes, address: UInt(bitPattern: mapping))
    }

    /// Makes the role's spare file in `directory` (zero, sized and allocated for a ring of `sizes`), so the
    /// next launch's ``adopt(_:directory:)`` renames it and skips the block allocation. It is built under a
    /// private name and renamed into place, so a launch never takes a half-made spare. Blocking file work.
    ///
    /// - Returns: whether a spare of that size is ready.
    @discardableResult
    public static func prepareSpare(directory: String, role: TraceRing.Role, sizes: TraceRing.Sizes) -> Bool {
        let byteCount = TraceRingLayout(sizes).totalBytes
        let path = directory + "/" + spareName(role: role)
        return blockingCall(.fileIO) {
            var info = stat()
            if stat(path, &info) == 0, Int(info.st_size) == byteCount { return true }
            let building = path + ".\(getpid()).tmp"
            let descriptor = open(building, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return false }
            let allocated = allocate(descriptor, byteCount: byteCount)
            close(descriptor)
            guard allocated, rename(building, path) == 0 else {
                unlink(building)
                return false
            }
            return true
        }
    }

    /// The whole records of the ring file at `path`, nil when it cannot be read or is not a v1 ring. The
    /// file is mapped read-only and decoded in place with the seqlock reads, so a ring whose process still
    /// writes decodes as safely as one whose process ended. Blocking file work.
    public static func records(atPath path: String) -> [TraceRecord]? {
        return blockingCall(.fileIO) {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, Int(info.st_size) >= TraceRing.headerBytes else { return nil }
            let byteCount = Int(info.st_size)
            let mapping = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0)
            guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
            // A reader's own mapping: unmapping it never affects the writer's.
            defer { munmap(mapping, byteCount) }
            // Loads only: the decoder never stores, so the read-only pages are never written.
            return TraceRingStorage(validating: mapping, byteCount: byteCount)?.decode()
        }
    }

    /// The decoded records of this file's mapping (the ring's records while it writes here).
    public func records() -> [TraceRecord] {
        guard let base = UnsafeMutableRawPointer(bitPattern: address),
              let storage = TraceRingStorage(validating: base, byteCount: byteCount) else { return [] }
        return storage.decode()
    }

    /// Takes the spare (when it has the right size) or creates `path`, and maps it. A taken spare is zeroed
    /// through the mapping (its blocks are already allocated; an old ring in it must not decode). A
    /// created file is sized and allocated first. `path` is never one this process has mapped: adoption
    /// is one-shot. Returns the mapping, or nil after removing the file.
    private static func map(path: String, spare: String, directory: String, byteCount: Int) -> UnsafeMutableRawPointer? {
        return blockingCall(.fileIO) {
            if mkdir(directory, 0o700) != 0, errno != EEXIST { return nil }
            if rename(spare, path) == 0, let mapping = mapSpare(path: path, byteCount: byteCount) {
                return mapping
            }
            let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            guard allocate(descriptor, byteCount: byteCount), let mapping = mapShared(descriptor, byteCount: byteCount) else {
                unlink(path)
                return nil
            }
            return mapping
        }
    }

    /// Maps a renamed spare of exactly `byteCount` bytes and zeroes it; nil for any other size.
    private static func mapSpare(path: String, byteCount: Int) -> UnsafeMutableRawPointer? {
        return blockingCall(.fileIO) {
            let descriptor = open(path, O_RDWR | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, Int(info.st_size) == byteCount,
                  let mapping = mapShared(descriptor, byteCount: byteCount) else { return nil }
            mapping.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            return mapping
        }
    }

    private static func mapShared(_ descriptor: Int32, byteCount: Int) -> UnsafeMutableRawPointer? {
        let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        return mapping
    }

    /// Gives an empty file `byteCount` zero bytes with their blocks allocated: `F_PREALLOCATE`, or, on a
    /// file system without it, one written zero byte per 4 KiB block, as Chrome's `MemoryMappedFile` does
    /// on macOS.
    private static func allocate(_ descriptor: Int32, byteCount: Int) -> Bool {
        return blockingCall(.fileIO) {
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
}

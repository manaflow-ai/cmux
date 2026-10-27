import CmuxNextCompat
import Darwin

extension TraceRingFile {
    /// A ring file's bytes as a file of it would read when its process stopped writing: every record whole or
    /// absent, and the header fields that say whose ring it is.
    public struct Snapshot: Sendable, Equatable {
        /// The ring's image (the bytes of ``TraceRing/image()`` for that ring).
        public let bytes: [UInt8]
        /// The writing process (header `pid`).
        public let pid: UInt32
        /// The writing process's kind; nil for a role this build does not know.
        public let role: TraceRing.Role?
        /// The writer's kernel start time in microseconds since 1970 (header `process_start_unix_us`); 0 when
        /// unknown. With ``pid`` it tells a live process from one whose pid was reused.
        public let processStartUnixMicros: UInt64
    }

    /// The ring file at `path` copied with the decode protocol (trace.md "Heap, then file", step 2), so a ring
    /// whose process still writes copies as safely as one whose process ended: the file is mapped read-only and
    /// copied into a private heap ring, which the copy only loads from. A byte copy of a live ring could keep a
    /// record whose writer was halfway through it. Nil when the file cannot be read or is not a v1 ring.
    /// Blocking file work: BackgroundWork `.files` only.
    public static func snapshot(atPath path: String) -> Snapshot? {
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
            // Loads only: the copy stores into its own heap ring, never into the read-only pages.
            guard let storage = TraceRingStorage(validating: mapping, byteCount: byteCount) else { return nil }
            let identity = storage.word(TraceRingOffsets.identityWord).load(ordering: .relaxed)
            return Snapshot(bytes: storage.snapshot(), pid: UInt32(truncatingIfNeeded: identity),
                            role: TraceRing.Role(rawValue: UInt16(truncatingIfNeeded: identity >> 32)),
                            processStartUnixMicros: storage.word(TraceRingOffsets.processStartUnixMicros).load(ordering: .relaxed))
        }
    }
}

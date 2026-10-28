// Public: the inlined key stores use the Compat `Atomic` and `AtomicPointerSlot` from other modules, and the
// `UInt: AtomicValue` conformance comes from swift-atomics.
public import Atomics
public import CmuxNextCompat
import Darwin

/// A process's crash-key page (plans/cmux-next/chrome-parity/p09-observability.md, task 078): one 4 KiB page
/// of 64-bit words at the fixed ``CrashKeySlot`` offsets, written with relaxed stores while the process runs.
/// The page lives on the heap and never moves; ``adopt(directory:)`` maps a `MAP_SHARED` file off the main thread
/// and mirrors the page into it, so what the process stored last stays in the page cache when it crashes, aborts
/// or is killed, and the next launch decodes it (``read(atPath:)``; tasks 079 and 110).
///
/// A key is stored into the heap page first, then into the file once one is mapped. Until the file holds a full
/// copy, a store runs a sequentially consistent fence between its heap store and its load of the mapping, and
/// the adoption runs one between publishing the mapping and reading the heap words: either the adoption copies
/// the store, or the store sees the mapping and writes the file itself. A key has one writer at a time (the
/// thread that runs its scope), as Chrome's crash keys do.
///
/// Chrome keeps each crash key in static storage that exists before the crash and that Crashpad reads from the
/// dead process (components/crash/core/common/crash_key.h); setting one is a store, never an allocation, and
/// `ScopedCrashKeyString` puts the outer value back (``ScopedCrashKey``, ``withKey(_:_:_:)``). cmux keeps
/// numbers only, never a person's text, so a page can go into a report as it is.
///
/// Layout (little-endian words): 0 magic `CMXKEYS1`; 1 version, header words `<< 16`, page words `<< 32`;
/// 2 pid, role `<< 32`; 3-4 the main image's `LC_UUID`; 5 process start (Unix microseconds); 6 the page's
/// start (`CLOCK_UPTIME_RAW` ns); 7 reserved; then the slots. Owner: PL-telemetry.
///
/// ```swift
/// let keys = CrashKeyPage(identity: .init(role: .app))       // composition root, before the first window
/// keys.set(.daemonPID, UInt64(pid))                           // any thread: relaxed stores, no lock
/// lanes.files { keys.adopt(directory: blackBoxDirectory) }    // off main, once
/// ```
public final class CrashKeyPage: Sendable {
    /// Who wrote a page, from its header.
    public struct Identity: Sendable, Equatable {
        public var pid: UInt32
        public var role: TraceRing.Role
        /// The main image's `LC_UUID` (16 bytes; shorter is zero padded, longer is cut).
        public var buildUUID: [UInt8]
        /// When the process started, Unix microseconds (0: unknown).
        public var processStartUnixMicros: UInt64
        /// When the page was made, `CLOCK_UPTIME_RAW` nanoseconds: ``CrashKeySlot/lastInputUptime`` and
        /// ``CrashKeySlot/hangInProgressStart`` are on the same clock.
        public var startUptimeNanos: UInt64

        /// - Parameter pid: The writing process; the calling one when nil.
        public init(pid: UInt32? = nil, role: TraceRing.Role, buildUUID: [UInt8] = [],
                    processStartUnixMicros: UInt64 = 0, startUptimeNanos: UInt64 = 0) {
            self.pid = pid ?? UInt32(bitPattern: getpid())
            self.role = role
            self.buildUUID = Array((buildUUID + [UInt8](repeating: 0, count: 16)).prefix(16))
            self.processStartUnixMicros = processStartUnixMicros
            self.startUptimeNanos = startUptimeNanos
        }
    }

    /// The header's magic: `CMXKEYS1` as little-endian bytes.
    public static var magic: UInt64 { 0x3153_5945_4B58_4D43 }
    /// The layout version; a reader rejects any other.
    public static var version: UInt64 { 1 }
    /// The page's size in bytes.
    public static var byteCount: Int { wordCount * 8 }
    @usableFromInline static var wordCount: Int { 512 }

    /// The page's file name for `role` in process `pid`, next to its black box (``TraceRingFile/fileName(role:pid:)``).
    public static func fileName(role: TraceRing.Role, pid: UInt32) -> String {
        "\(role.fileStem)-\(pid).crashkeys"
    }

    /// The heap page from `init`: every key is stored here first and read from here; it never moves.
    @usableFromInline let heap: UInt
    /// The file's mapping the keys are mirrored into: 0 before ``adopt(directory:)`` maps one, its address with
    /// bit 0 set while the adoption copies the heap page in, the bare address once the copy is done (the mapping
    /// is page aligned, so bit 0 is free).
    @usableFromInline let mirror = Atomic<UInt>(0)
    /// 0 on the heap, 1 adopting, 2 in the file.
    private let adoption = Atomic<Int>(0)
    private let adoptFailureCount = Atomic<Int>(0)
    /// The header this page was made with.
    public let identity: Identity

    /// An empty page on the heap with `identity`'s header.
    public init(identity: Identity) {
        self.identity = identity
        let page = UnsafeMutableRawPointer.allocate(byteCount: Self.byteCount, alignment: Self.byteCount)
        page.initializeMemory(as: UInt64.self, repeating: 0, count: Self.wordCount)
        heap = UInt(bitPattern: page)
        let words = page.assumingMemoryBound(to: UInt64.self)
        let header = Self.header(identity)
        for (index, value) in header.enumerated() {
            AtomicPointerSlot(words + index).store(value, ordering: .relaxed)
        }
    }

    deinit {
        // Every store goes through this instance, so none can run now.
        if let file = UnsafeMutableRawPointer(bitPattern: mirror.load(ordering: .acquiring) & ~1) {
            munmap(file, Self.byteCount)
        }
        UnsafeMutableRawPointer(bitPattern: heap)?.deallocate()
    }

    // MARK: - Keys

    /// Stores `value` in the first word of `slot`: a relaxed store into the heap page, and one into the file once
    /// it is mapped (``store(_:_:)``).
    @inlinable @inline(__always)
    public func set(_ slot: CrashKeySlot, _ value: UInt64) {
        store(Int(slot.rawValue), value)
    }

    /// The value in the first word of `slot` (0 when never set).
    @inlinable @inline(__always)
    public func value(_ slot: CrashKeySlot) -> UInt64 {
        heapWord(Int(slot.rawValue)).load(ordering: .relaxed)
    }

    /// Stores the bucket of `count` (``countBucket(_:)``) in a count slot (``CrashKeySlot/windowCount`` through
    /// ``CrashKeySlot/webKitViewCount``).
    @inlinable @inline(__always)
    public func setCount(_ slot: CrashKeySlot, _ count: Int) {
        set(slot, Self.countBucket(count))
    }

    /// A count as the page keeps it: 0, or the largest power of two not above it (1, 2, 4, 8 …), so a report
    /// says "8 to 15 workspaces", as Chrome's crash keys and UMA count buckets do.
    @inlinable @inline(__always)
    public static func countBucket(_ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        return 1 << (63 - UInt64(count).leadingZeroBitCount)
    }

    /// Runs `body` with `slot` set to `value`, then puts the value it replaced back (Chrome's
    /// `ScopedCrashKeyString`): a nested action run puts the outer run's key back when it returns. The key
    /// belongs to the thread that runs `body`.
    @inlinable @inline(__always)
    public func withKey<T>(_ slot: CrashKeySlot, _ value: UInt64, _ body: () throws -> T) rethrows -> T {
        let outer = self.value(slot)
        set(slot, value)
        defer { set(slot, outer) }
        return try body()
    }

    // MARK: - Hang in progress (task 110)

    /// The most frames ``beginHang(startNanos:frames:imageUUIDWords:)`` keeps.
    public static var hangFrameCapacity: Int { CrashKeySlot.hangInProgressFrames.wordCount }

    /// A hang frame's word: the image's index in the image list (high 16 bits) and the offset in that image
    /// (low 48 bits).
    public static func packedFrame(image: Int, offset: UInt64) -> UInt64 {
        UInt64(UInt16(truncatingIfNeeded: image)) << 48 | offset & 0x0000_FFFF_FFFF_FFFF
    }

    /// Records the main thread's stall in progress (the watchdog, at 2 s): its frames, innermost first
    /// (``packedFrame(image:offset:)``; at most ``hangFrameCapacity``), and the images they point into as two
    /// words per `LC_UUID` (at most 16 images). The start goes last, so a page with a start has its frames.
    public func beginHang(startNanos: UInt64, frames: [UInt64], imageUUIDWords: [UInt64]) {
        set(.hangInProgressStart, 0)
        let images = min(imageUUIDWords.count, CrashKeySlot.hangInProgressImages.wordCount)
        for index in 0 ..< CrashKeySlot.hangInProgressImages.wordCount {
            store(Int(CrashKeySlot.hangInProgressImages.rawValue) + index, index < images ? imageUUIDWords[index] : 0)
        }
        let count = min(frames.count, Self.hangFrameCapacity)
        for index in 0 ..< Self.hangFrameCapacity {
            store(Int(CrashKeySlot.hangInProgressFrames.rawValue) + index, index < count ? frames[index] : 0)
        }
        set(.hangInProgressFrameCount, UInt64(count))
        set(.hangInProgressStart, startNanos)
    }

    /// The stall ended: the page no longer reports a hang in progress.
    public func endHang() {
        set(.hangInProgressStart, 0)
        set(.hangInProgressFrameCount, 0)
    }

    // MARK: - Adoption

    /// Whether the page lives in its file now.
    public var isFileBacked: Bool { adoption.load(ordering: .acquiring) == 2 }

    /// The adoptions that failed (no directory, no file, no mapping); the page stays on the heap.
    public var adoptFailures: Int { adoptFailureCount.load(ordering: .relaxed) }

    /// Mirrors the page into `role-pid.crashkeys` in `directory` (mode 0700, made when missing): creates the file
    /// with its block allocated (a store into a sparse page on a full disk would end the process with SIGBUS, as
    /// Chrome's `MemoryMappedFile` notes), maps it `MAP_SHARED`, publishes the mapping to the writers, then copies
    /// each heap word in (``copy(_:into:)``), so a key stored at any point of the adoption reaches the file.
    /// Blocking file work: run it on BackgroundWork `.files`, never on main. One-shot: a second call returns nil.
    ///
    /// - Returns: The file's path, or nil (counted in ``adoptFailures`` when the file work failed).
    @discardableResult
    public func adopt(directory: String) -> String? {
        guard adoption.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else { return nil }
        let path = directory + "/" + Self.fileName(role: identity.role, pid: identity.pid)
        guard let mapping = Self.mapFile(path: path, directory: directory),
              let source = UnsafeMutablePointer<UInt64>(bitPattern: heap) else {
            adoptFailureCount.add(1, ordering: .relaxed)
            adoption.store(0, ordering: .releasing)
            return nil
        }
        let file = UInt(bitPattern: mapping)
        // Pairs with the fence in `store(_:_:)`: a writer stored before this fence (the copy below reads it), or
        // loads the mapping after it and stores into the file itself.
        mirror.store(file | 1, ordering: .sequentiallyConsistent)
        atomicFence(ordering: .sequentiallyConsistent)
        let target = mapping.assumingMemoryBound(to: UInt64.self)
        for index in 0 ..< Self.wordCount {
            Self.copy(AtomicPointerSlot(source + index), into: AtomicPointerSlot(target + index))
        }
        // Every word is in the file: from here a store skips the fence.
        mirror.store(file, ordering: .releasing)
        adoption.store(2, ordering: .releasing)
        return path
    }

    /// Copies one heap word into its file word, again while the heap holds another value after a fence (a store
    /// raced the copy; the retry ends at the first copy no store interleaves, like a compare-exchange loop). A
    /// writer whose heap store comes after the copy's read changes the heap (copied again); a writer whose file
    /// store comes before the copy's store is ordered before that fence, so the check reads its heap store.
    private static func copy(_ source: AtomicPointerSlot, into target: AtomicPointerSlot) {
        var copied = source.load(ordering: .relaxed)
        target.store(copied, ordering: .relaxed)
        atomicFence(ordering: .sequentiallyConsistent)
        var now = source.load(ordering: .relaxed)
        while now != copied {
            copied = now
            target.store(copied, ordering: .relaxed)
            atomicFence(ordering: .sequentiallyConsistent)
            now = source.load(ordering: .relaxed)
        }
    }

    // MARK: - Reading

    /// The page's words now, with relaxed loads.
    public func snapshot() -> Snapshot {
        let words = (0 ..< Self.wordCount).map { heapWord($0).load(ordering: .relaxed) }
        return Snapshot(identity: identity, words: words)
    }

    /// The page in the file at `path` (a previous launch's, or this one's), nil when it cannot be read or is not
    /// a v1 page. Blocking file work.
    public static func read(atPath path: String) -> Snapshot? {
        let bytes: [UInt8]? = blockingCall(.fileIO) {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var buffer = [UInt8](repeating: 0, count: byteCount)
            let read = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, byteCount, 0) }
            return read == byteCount ? buffer : nil
        }
        return bytes.flatMap { decode($0) }
    }

    /// The page in `bytes` (at least ``byteCount``), nil when its header is not a v1 page's.
    public static func decode(_ bytes: [UInt8]) -> Snapshot? {
        guard bytes.count >= byteCount else { return nil }
        let words = bytes.withUnsafeBytes { raw in
            (0 ..< wordCount).map { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
        }
        let shape = version | UInt64(CrashKeySlot.headerWordCount) << 16 | UInt64(wordCount) << 32
        guard words[0] == magic, words[1] == shape,
              let role = TraceRing.Role(rawValue: UInt16(truncatingIfNeeded: words[2] >> 32)) else { return nil }
        let uuid = (words[3].littleEndianBytes + words[4].littleEndianBytes)
        let identity = Identity(pid: UInt32(truncatingIfNeeded: words[2]), role: role, buildUUID: uuid,
                                processStartUnixMicros: words[5], startUptimeNanos: words[6])
        return Snapshot(identity: identity, words: words)
    }

    // MARK: - Internals

    /// Stores `value` in word `index` of the heap page, then of the file's mapping when there is one. Until the
    /// adoption's copy is done (no mapping yet, or bit 0 set), a sequentially consistent fence orders the heap
    /// store before the reload of ``mirror``; the adoption's side is in ``adopt(directory:)``.
    @inlinable @inline(__always)
    func store(_ index: Int, _ value: UInt64) {
        heapWord(index).store(value, ordering: .relaxed)
        var file = mirror.load(ordering: .acquiring)
        if file == 0 || file & 1 != 0 {
            atomicFence(ordering: .sequentiallyConsistent)
            file = mirror.load(ordering: .acquiring)
        }
        // The mapping stays while `self` lives, and every index is a slot's word (below 512).
        guard let target = UnsafeMutablePointer<UInt64>(bitPattern: file & ~1) else { return }
        AtomicPointerSlot(target + index).store(value, ordering: .relaxed)
    }

    @inlinable @inline(__always)
    func heapWord(_ index: Int) -> AtomicPointerSlot {
        // The heap page from `init` stays while `self` lives, and every index is a slot's word (below 512).
        AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: heap).unsafelyUnwrapped + index)
    }

    private static func header(_ identity: Identity) -> [UInt64] {
        let uuid = identity.buildUUID
        let low = uuid.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let high = uuid.dropFirst(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return [
            magic,
            version | UInt64(CrashKeySlot.headerWordCount) << 16 | UInt64(wordCount) << 32,
            UInt64(identity.pid) | UInt64(identity.role.rawValue) << 32,
            low, high,
            identity.processStartUnixMicros,
            identity.startUptimeNanos,
            0,
        ]
    }

    /// Creates `path` (truncating an old one: a pid is this launch's), writes one zero page so its block is
    /// allocated, and maps it. Returns the mapping, or nil after removing the file.
    private static func mapFile(path: String, directory: String) -> UnsafeMutableRawPointer? {
        return blockingCall(.fileIO) {
            if mkdir(directory, 0o700) != 0, errno != EEXIST { return nil }
            let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            let zero = [UInt8](repeating: 0, count: byteCount)
            let written = zero.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, byteCount, 0) }
            let mapping: UnsafeMutableRawPointer? = written == byteCount
                ? mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0) : nil
            guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else {
                unlink(path)
                return nil
            }
            return mapping
        }
    }
}

extension CrashKeyPage {
    /// A page's words read back: a previous launch's file or a live page.
    public struct Snapshot: Sendable, Equatable {
        /// The header's identity.
        public let identity: Identity
        /// Every word of the page (512), the header first.
        public let words: [UInt64]

        /// The first word of `slot`.
        public subscript(slot: CrashKeySlot) -> UInt64 { words[Int(slot.rawValue)] }

        /// Every word of `slot`.
        public func slotWords(_ slot: CrashKeySlot) -> ArraySlice<UInt64> {
            let start = Int(slot.rawValue)
            return words[start ..< start + slot.wordCount]
        }

        /// The stall the page recorded as in progress, nil when none was.
        public var hangInProgress: (startNanos: UInt64, frames: [UInt64], imageUUIDWords: [UInt64])? {
            let start = self[.hangInProgressStart]
            guard start != 0 else { return nil }
            let count = min(Int(self[.hangInProgressFrameCount]), CrashKeyPage.hangFrameCapacity)
            return (start, Array(slotWords(.hangInProgressFrames).prefix(count)), Array(slotWords(.hangInProgressImages)))
        }

        /// The single-word keys that are set, as a report's tags (`crash_key.<name>`): decimal numbers, the Ghostty
        /// commit in hex, the unclosed agent pane as `<maker>@<uptime s>` (``CrashKeySlot/unclosedAgentPane(_:)``;
        /// compare with ``CrashKeySlot/lastInputUptime`` or the report's uptime). The hang's frames and images are not tags.
        public var tags: [String: String] {
            var tags: [String: String] = [:]
            for slot in CrashKeySlot.allCases where slot.wordCount == 1 && self[slot] != 0 {
                let value = self[slot]
                switch slot {
                case .ghosttyCommit: tags["crash_key.\(slot.name)"] = String(value, radix: 16)
                case .unclosedAgentPaneMaker:
                    let (maker, uptime) = CrashKeySlot.unclosedAgentPane(value)
                    let millis = uptime / 1_000_000
                    // Three digits: 1000 plus the remainder, without its leading 1.
                    tags["crash_key.\(slot.name)"] = "\(maker)@\(millis / 1000)." + String(1000 + millis % 1000).dropFirst() + "s"
                default: tags["crash_key.\(slot.name)"] = String(value)
                }
            }
            return tags
        }
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: self >> (8 * UInt64($0))) } }
}

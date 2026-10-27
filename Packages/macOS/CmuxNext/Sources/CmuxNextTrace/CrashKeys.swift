// Public: the inlined key stores use the Compat `Atomic` and `AtomicPointerSlot` from other modules, and the
// `UInt: AtomicValue` conformance comes from swift-atomics.
public import Atomics
public import CmuxNextCompat
import Darwin

/// A process's crash-key page (plans/cmux-next/chrome-parity/p09-observability.md, task 078): one 4 KiB page
/// of 64-bit words at the fixed ``CrashKeySlot`` offsets, written with relaxed stores while the process runs.
/// It starts on the heap; ``adopt(directory:)`` moves it into a `MAP_SHARED` file off the main thread, so what
/// the process stored last stays in the page cache when it crashes, aborts or is killed, and the next launch
/// decodes it (``read(atPath:)``; tasks 079 and 110).
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
/// keys.set(.daemonPID, UInt64(pid))                           // any thread, one relaxed store
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

    /// The page the writers store into: the heap page, then the file's mapping. Every store loads it with acquire,
    /// so a store after the swap lands after the adoption's copy.
    @usableFromInline let active = Atomic<UInt>(0)
    private let heap: UInt
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
        active.store(heap, ordering: .releasing)
    }

    deinit {
        // Every store goes through this instance, so none can run now.
        if adoption.load(ordering: .acquiring) == 2, let file = UnsafeMutableRawPointer(bitPattern: active.load(ordering: .relaxed)) {
            munmap(file, Self.byteCount)
        }
        UnsafeMutableRawPointer(bitPattern: heap)?.deallocate()
    }

    // MARK: - Keys

    /// Stores `value` in the first word of `slot` (one relaxed store).
    @inlinable @inline(__always)
    public func set(_ slot: CrashKeySlot, _ value: UInt64) {
        word(Int(slot.rawValue)).store(value, ordering: .relaxed)
    }

    /// The value in the first word of `slot` (0 when never set).
    @inlinable @inline(__always)
    public func value(_ slot: CrashKeySlot) -> UInt64 {
        word(Int(slot.rawValue)).load(ordering: .relaxed)
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
            word(Int(CrashKeySlot.hangInProgressImages.rawValue) + index)
                .store(index < images ? imageUUIDWords[index] : 0, ordering: .relaxed)
        }
        let count = min(frames.count, Self.hangFrameCapacity)
        for index in 0 ..< Self.hangFrameCapacity {
            word(Int(CrashKeySlot.hangInProgressFrames.rawValue) + index).store(index < count ? frames[index] : 0, ordering: .relaxed)
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

    /// Moves the page into `role-pid.crashkeys` in `directory` (mode 0700, made when missing): creates the file
    /// with its block allocated (a store into a sparse page on a full disk would end the process with SIGBUS, as
    /// Chrome's `MemoryMappedFile` notes), maps it `MAP_SHARED`, copies the heap words in and points the writers at
    /// it; a key stored on the heap while it copied is carried over after the swap.
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
        let target = mapping.assumingMemoryBound(to: UInt64.self)
        var copied = [UInt64](repeating: 0, count: Self.wordCount)
        for index in 0 ..< Self.wordCount {
            copied[index] = AtomicPointerSlot(source + index).load(ordering: .relaxed)
            AtomicPointerSlot(target + index).store(copied[index], ordering: .relaxed)
        }
        active.store(UInt(bitPattern: mapping), ordering: .releasing)
        // A key stored on the heap during the copy moves too, unless the file already has a newer store.
        for index in 0 ..< Self.wordCount {
            let late = AtomicPointerSlot(source + index).load(ordering: .relaxed)
            if late != copied[index] {
                AtomicPointerSlot(target + index).compareExchange(expected: copied[index], desired: late, ordering: .relaxed)
            }
        }
        adoption.store(2, ordering: .releasing)
        return path
    }

    // MARK: - Reading

    /// The page's words now, with relaxed loads.
    public func snapshot() -> Snapshot {
        let words = (0 ..< Self.wordCount).map { word($0).load(ordering: .relaxed) }
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

    @inlinable @inline(__always)
    func word(_ index: Int) -> AtomicPointerSlot {
        // `active` is the heap page from `init`, then the file's mapping; both stay while `self` lives, and every
        // index is a slot's word (below 512).
        AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: active.load(ordering: .acquiring)).unsafelyUnwrapped + index)
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

/// Sets a crash key for the life of the value and puts the value it replaced back when it ends (Chrome's
/// `ScopedCrashKeyString`, components/crash/core/common/crash_key.h). Noncopyable, so it ends once.
///
/// ```swift
/// let scope = ScopedCrashKey(keys, .inCEFPump, 1)
/// pump()
/// scope.end()                                  // or at the end of the scope
/// ```
public struct ScopedCrashKey: ~Copyable {
    private let page: CrashKeyPage
    private let slot: CrashKeySlot
    private let outer: UInt64

    /// Sets `slot` to `value` on `page`.
    public init(_ page: CrashKeyPage, _ slot: CrashKeySlot, _ value: UInt64) {
        self.page = page
        self.slot = slot
        outer = page.value(slot)
        page.set(slot, value)
    }

    /// Puts the outer value back now.
    public consuming func end() {}

    deinit {
        page.set(slot, outer)
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
        /// commit in hex. The hang's frames and images are not tags.
        public var tags: [String: String] {
            var tags: [String: String] = [:]
            for slot in CrashKeySlot.allCases where slot.wordCount == 1 && self[slot] != 0 {
                let value = self[slot]
                tags["crash_key.\(slot.name)"] = slot == .ghosttyCommit ? String(value, radix: 16) : String(value)
            }
            return tags
        }
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: self >> (8 * UInt64($0))) } }
}

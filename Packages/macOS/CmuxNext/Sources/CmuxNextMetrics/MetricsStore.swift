import CmuxNextCompat
public import CmuxNextTrace
import Darwin

/// A process's field histograms: one counter block per catalog histogram, first on the heap, then in a
/// per-launch `MAP_SHARED` file that survives a crash (plans/cmux-next/chrome-parity/p09-observability.md
/// section 3D, task 052).
///
/// Chrome's model: `base::GlobalHistogramAllocator` starts on the heap, `CreateWithActiveFileInDir` moves it into
/// a mapped file on a background task, and the next launch renames a spare file made at low priority
/// (base/metrics/persistent_histogram_allocator.cc, components/metrics/persistent_histograms.cc). Each histogram's
/// samples are counted in place in that memory (base/metrics/persistent_sample_map.cc), and
/// `base::HistogramSnapshotManager` uploads only what was recorded since the last upload.
///
/// - A record (``Metrics/record(_:_:)``) is one dictionary probe and three relaxed atomic adds (bucket, count,
///   sum) into the active block: no lock, allocation or system call, on any thread.
/// - An expired histogram (``HistogramID/Expiry``, by the profile's build day) and Chromium's own have no block
///   and record nothing.
/// - Each block has a "logged" shadow of its counters. ``delta()`` reads current minus logged, and
///   ``markLogged(_:)`` adds an uploaded delta to the shadow, so each sample is sent once. Both run under the
///   store's shadow lock, as Chrome takes `StatisticsRecorder`'s snapshot lock around a delta
///   (base/metrics/statistics_recorder.cc); records never take it.
/// - ``adoptFile(directory:)`` (blocking file work, BackgroundWork `.files`) renames the spare or creates
///   `metrics-<role>-<pid>.bin` and writes the header and directory outside the lock. Under the lock it swaps
///   the writers to the file and adds the heap's counters and logged shadow into it, so a delta or a mark sees
///   the whole heap block or the whole file block, never one half-folded. A record whose writer read the heap
///   address before the swap and adds after the fold is lost. The file stays mapped while the store lives; an
///   attached store lives as long as its process.
///
/// File layout (little-endian; the Rust writers of task 131 use the same):
///
/// | Offset | Field |
/// | --- | --- |
/// | 0 | magic `CMXMETRC` (8 bytes) |
/// | 8 | version u32 (1) |
/// | 12 | directory offset u32 (1024) |
/// | 16 | histogram count u32 |
/// | 20 | role u16 (`TraceRuntime.Role`) |
/// | 22 | sub-buckets per power of two, as a shift, u16 (2) |
/// | 24 | pid u32 |
/// | 28 | directory entry bytes u32 (88) |
/// | 32 | start uptime ns u64 (`TraceClock`) |
/// | 40 | start wall clock ns since 1970 u64 |
/// | 48 | file bytes u64 |
/// | 56 | first block offset u64 |
/// | 64 | profile: boot session (16), build UUID (16), build day u32 `yyyymmdd` at 96, then five 64-byte NUL-padded texts at 104: version, build, channel, OS version, hardware class |
///
/// A directory entry (88 bytes): name (64 bytes, NUL padded), kind u32 (1 log-linear, 2 linear, 3 enumeration),
/// bucket count u32 (overflow included), maximum or value count i64, block offset u64. A block (64-byte aligned)
/// is u64 words: count, sum, the buckets, then the logged count, sum and buckets.
///
/// ```swift
/// let store = MetricsStore(role: .app, profile: .current(channel: "nightly", buildDay: day))
/// store.attach(to: .shared)
/// work.postFiles(.userVisible, shutdown: .skipOnShutdown) { _ = store.adoptFile(directory: path) }
/// ```
public final class MetricsStore: Sendable {
    /// The process kind in the header and the file name.
    public let role: TraceRuntime.Role
    /// The pid in the header and the file name.
    public let pid: UInt32
    /// The system profile in the header.
    public let profile: MetricsProfile
    /// The histograms that have a block, in directory order.
    public let histograms: [HistogramID]
    /// The bytes of the heap block and the file.
    public let byteCount: Int
    /// Where each recording histogram's counters are.
    let slots: [HistogramID: Slot]
    /// The header and directory, written into the heap now and into the file at adoption.
    private let image: [UInt8]
    /// The heap block (freed in deinit, when no writer is left).
    private let heapAddress: UInt
    /// The block writers add to: the heap, then the file.
    private let activeAddress = Atomic<UInt64>(0)
    /// The file mapping, 0 until adoption.
    private let fileAddress = Atomic<UInt64>(0)
    /// 0 before adoption, 1 while it runs, 2 after it succeeded.
    private let adoption = Atomic<UInt64>(0)
    /// The block whose logged shadow ``delta()`` and ``markLogged(_:)`` use: the heap, then the file. The adoption
    /// changes it in the same critical section as its swap and fold.
    private let shadow: Mutex<UInt>

    /// A store whose counters start on the heap; no file work. Attach it to the process's runtime with
    /// ``attach(to:)`` so every ``Metrics`` of the process records into it.
    ///
    /// - Parameters:
    ///   - role: The process kind.
    ///   - profile: The system profile; its build day decides which histograms have expired.
    ///   - pid: The process; nil for the calling one.
    ///   - catalog: The histograms (the whole catalog by default; tests pass fewer).
    ///   - clock: The clock of the header's start time.
    public init(role: TraceRuntime.Role, profile: MetricsProfile, pid: UInt32? = nil,
                catalog: [HistogramID] = HistogramID.allCases, clock: TraceClock = TraceClock()) {
        let processID = pid ?? UInt32(bitPattern: getpid())
        var layout = Layout(catalog: catalog.filter { $0.records(builtOn: profile.buildDay) })
        layout.header = Header(role: role, pid: processID, startUptimeNanos: clock.nowNanos(),
                               startUnixNanos: clock_gettime_nsec_np(CLOCK_REALTIME), profile: profile)
        let image = layout.image(), byteCount = layout.byteCount
        let heap = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: Self.blockAlignment)
        heap.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        heap.copyMemory(from: image, byteCount: image.count)
        self.role = role
        self.pid = processID
        self.profile = profile
        self.image = image
        self.byteCount = byteCount
        histograms = layout.entries.map(\.id)
        slots = layout.slots
        heapAddress = UInt(bitPattern: heap)
        shadow = Mutex(UInt(bitPattern: heap))
        activeAddress.store(UInt64(heapAddress), ordering: .releasing)
    }

    deinit {
        // A writer holds the store, so none is left: the heap and the file can go.
        UnsafeMutableRawPointer(bitPattern: heapAddress)?.deallocate()
        if let file = UnsafeMutableRawPointer(bitPattern: UInt(fileAddress.load(ordering: .acquiring))) {
            munmap(file, byteCount)
        }
    }

    /// Makes this the store every `Metrics(runtime:)` of `runtime` records into.
    ///
    /// - Returns: false when `runtime` has a store already (that one stays; ``attached(to:)`` returns it).
    @discardableResult
    public func attach(to runtime: TraceRuntime) -> Bool {
        runtime.attachMetrics(self)
    }

    /// The store attached to `runtime`, nil before one is.
    public static func attached(to runtime: TraceRuntime) -> MetricsStore? {
        runtime.attachedMetrics.map { unsafeDowncast($0.takeUnretainedValue(), to: MetricsStore.self) }
    }

    // MARK: recording

    /// Adds `sample` to `id`'s bucket, count and sum: three relaxed adds, nothing for a histogram with no block.
    // perf-hot: 200ns metrics-record
    @inline(__always)
    func record(_ id: HistogramID, _ sample: Int64) {
        guard let slot = slots[id],
              let words = UnsafeMutablePointer<UInt64>(bitPattern: UInt(activeAddress.load(ordering: .acquiring))) else { return }
        let block = words + slot.word
        AtomicPointerSlot(block + 2 + slot.bucket(of: sample)).add(1, ordering: .relaxed)
        AtomicPointerSlot(block).add(1, ordering: .relaxed)
        AtomicPointerSlot(block + 1).add(UInt64(max(sample, 0)), ordering: .relaxed)
    }

    /// Adds a child process's samples of `id` (``Metrics/record(_:folding:)``, counted in `id`'s layout): relaxed adds
    /// to the buckets, count and sum. False for a histogram with no block.
    func add(_ id: HistogramID, count: UInt64, sum: UInt64, buckets: [MetricsDelta.Bucket]) -> Bool {
        guard let slot = slots[id],
              let words = UnsafeMutablePointer<UInt64>(bitPattern: UInt(activeAddress.load(ordering: .acquiring))) else { return false }
        let block = words + slot.word
        for bucket in buckets where bucket.index >= 0 && bucket.index <= slot.overflow {
            AtomicPointerSlot(block + 2 + bucket.index).add(bucket.count, ordering: .relaxed)
        }
        AtomicPointerSlot(block).add(count, ordering: .relaxed)
        AtomicPointerSlot(block + 1).add(sum, ordering: .relaxed)
        return true
    }

    // MARK: delta upload

    /// What was recorded since the last ``markLogged(_:)``: current minus logged, per histogram with samples.
    /// Waits while an adoption folds the heap into the file.
    public func delta() -> MetricsDelta {
        shadow.withLock { address in
            shadowImage(at: address)?.delta() ?? MetricsDelta(profile: profile, histograms: [])
        }
    }

    /// Every sample since the store was made, uploads or not, per histogram with samples (``MetricsImage/totals()``):
    /// what `metrics.snapshot` and View Metrics show. Waits while an adoption folds the heap into the file.
    public func totals() -> MetricsDelta {
        shadow.withLock { address in
            shadowImage(at: address)?.totals() ?? MetricsDelta(profile: profile, histograms: [])
        }
    }

    /// Adds an uploaded `delta` (from ``delta()``) to the logged shadow, so the next delta leaves its samples out.
    /// One owner (the report uploader) calls it, once per delta, after the upload succeeded. Waits while an
    /// adoption folds the heap into the file.
    public func markLogged(_ delta: MetricsDelta) {
        shadow.withLock { address in
            guard let image = shadowImage(at: address) else { return }
            image.markLogged(delta)
        }
    }

    /// The block at `address`, heap or file (always a valid image: this store wrote its header).
    private func shadowImage(at address: UInt) -> MetricsImage? {
        UnsafeMutableRawPointer(bitPattern: address).flatMap { MetricsImage(validating: $0, byteCount: byteCount) }
    }

    // MARK: file

    /// The metrics file name of `role` in process `pid` (Rust's `metrics-<role>-<pid>.bin`, task 131).
    public static func fileName(role: TraceRuntime.Role, pid: UInt32) -> String {
        "metrics-\(stem(of: role))-\(pid).bin"
    }

    /// The spare file a later launch of `role` renames instead of creating its file.
    public static func spareName(role: TraceRuntime.Role) -> String {
        "metrics-\(stem(of: role)).spare.bin"
    }

    /// Whether the counters live in the file now.
    public var isFileBacked: Bool { adoption.load(ordering: .acquiring) == 2 }

    /// Moves the counters into `directory`/``fileName(role:pid:)``: renames the role's spare when it has this
    /// store's size or creates the file, maps it `MAP_SHARED`, writes the header and directory, then, under the
    /// shadow lock, swaps the writers to it and adds the heap's counters and logged shadow into it. Blocking file
    /// work: BackgroundWork `.files`, never main. One-shot: a second call returns nil.
    ///
    /// - Returns: The file's path, or nil when the counters stay on the heap.
    @discardableResult
    public func adoptFile(directory: String) -> String? {
        assertBlockingAllowed(.fileIO)
        guard adoption.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else { return nil }
        let path = directory + "/" + Self.fileName(role: role, pid: pid)
        guard Self.makeDirectory(directory),
              let file = Self.map(path: path, spare: directory + "/" + Self.spareName(role: role), byteCount: byteCount) else {
            adoption.store(0, ordering: .releasing)
            return nil
        }
        file.copyMemory(from: image, byteCount: image.count)
        let fileWord = UInt(bitPattern: file)
        fileAddress.store(UInt64(fileWord), ordering: .releasing)
        let heap = UnsafeMutableRawPointer(bitPattern: heapAddress)?.assumingMemoryBound(to: UInt64.self)
        let words = file.assumingMemoryBound(to: UInt64.self)
        let blockWords = image.count / 8 ..< byteCount / 8
        shadow.withLock { address in
            activeAddress.store(UInt64(fileWord), ordering: .releasing)
            for word in blockWords {
                let value = heap.map { AtomicPointerSlot($0 + word).load(ordering: .relaxed) } ?? 0
                if value != 0 { AtomicPointerSlot(words + word).add(value, ordering: .relaxed) }
            }
            address = fileWord
        }
        adoption.store(2, ordering: .releasing)
        return path
    }

    /// Makes the role's spare file in `directory` for the next launch: zero, sized for this store and its blocks
    /// allocated, built under a private name and renamed into place. Blocking file work: BackgroundWork `.files`
    /// at a low priority, well after launch.
    ///
    /// - Returns: Whether a spare of this size is ready.
    @discardableResult
    public func prepareSpare(directory: String) -> Bool {
        assertBlockingAllowed(.fileIO)
        let path = directory + "/" + Self.spareName(role: role)
        let byteCount = byteCount
        guard Self.makeDirectory(directory) else { return false }
        return blockingCall(.fileIO) {
            var info = stat()
            if stat(path, &info) == 0, Int(info.st_size) == byteCount { return true }
            let building = path + ".\(getpid()).tmp"
            let descriptor = open(building, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return false }
            let allocated = Self.allocate(descriptor, byteCount: byteCount)
            close(descriptor)
            guard allocated, rename(building, path) == 0 else {
                unlink(building)
                return false
            }
            return true
        }
    }

    /// The file-name stem of `role` (the trace ring's: `app`, `terminal-host`).
    private static func stem(of role: TraceRuntime.Role) -> String {
        TraceRing.Role(rawValue: role.rawValue)?.fileStem ?? "unknown"
    }

    /// Creates `path` and its missing parents (mode 0700); true when it is a directory afterwards.
    private static func makeDirectory(_ path: String) -> Bool {
        return blockingCall(.fileIO) {
            var info = stat()
            if stat(path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
            var prefix = ""
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                prefix += "/" + component
                if mkdir(prefix, 0o700) != 0, errno != EEXIST { return false }
            }
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
    }

    /// Renames the spare to `path` when it has `byteCount` bytes (``prepareSpare(directory:)`` made it zero), else
    /// creates `path` sized and allocated; maps it. Nil after removing a file it could not map.
    private static func map(path: String, spare: String, byteCount: Int) -> UnsafeMutableRawPointer? {
        return blockingCall(.fileIO) {
            var info = stat()
            if stat(spare, &info) == 0, Int(info.st_size) == byteCount, rename(spare, path) == 0 {
                let descriptor = open(path, O_RDWR | O_CLOEXEC)
                if descriptor >= 0 {
                    defer { close(descriptor) }
                    if let mapping = mapShared(descriptor, byteCount: byteCount) { return mapping }
                }
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

    private static func mapShared(_ descriptor: Int32, byteCount: Int) -> UnsafeMutableRawPointer? {
        let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        return mapping
    }

    /// Gives an empty file `byteCount` zero bytes with their blocks allocated (`F_PREALLOCATE`, else one written
    /// zero byte per 4 KiB block), so a counter add into a sparse page on a full disk cannot end the process with
    /// SIGBUS (Chrome's `MemoryMappedFile` `READ_WRITE_EXTEND`, base/files/memory_mapped_file_posix.cc).
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

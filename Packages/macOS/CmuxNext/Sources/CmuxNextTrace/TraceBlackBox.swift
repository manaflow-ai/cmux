import CmuxNextCompat
import Darwin
import MachO

/// One process's black box: its trace ring from launch, sized by role, with the black-box categories on
/// (plans/cmux-next/chrome-parity/p09-observability.md section 3A, trace.md "One write path").
///
/// Making it touches memory only: the ring starts on the heap at once and is attached to the runtime
/// (``TraceRuntime/attach(_:)``), which owns it from then on, so every `runtime.write` of the process
/// records into it from the first frame; nothing opens, truncates or maps a file on the caller's thread. The
/// three file steps are separate blocking calls that the owner runs on BackgroundWork `.files`. The process's
/// crash-key page (``crashKeys``) starts on the heap beside the ring and is mirrored into its file with it:
///
/// 1. ``adoptFile()``: moves the ring into `<directory>/<role>-<pid>.blackbox.cmxtrace` (``TraceRingFile``),
///    renaming the role's spare file when one is ready, and the page into `<role>-<pid>.crashkeys`.
/// 2. ``cleanUp(now:)``: deletes the black boxes and pages of dead processes (``TraceRingCleanup``).
/// 3. ``prepareSpare()``: makes the next launch's spare file, well after launch.
///
/// Chrome does the same with its persistent histogram file: the browser starts on a heap allocator,
/// `base::GlobalHistogramAllocator::CreateWithActiveFileInDir` moves it into a mapped file on a background
/// task, and `CreateSpareFile` writes `BrowserMetrics-spare.pma` at low priority for the next launch
/// (base/metrics/persistent_histogram_allocator.cc, components/metrics/persistent_histograms.cc).
///
/// ```swift
/// let blackBox = TraceBlackBox(role: .app, directory: path, runtime: .shared, buildVersion: version)
/// work.post(.userVisible, mayBlock: .files) { _ = blackBox.adoptFile() }
/// ```
public final class TraceBlackBox: Sendable {
    /// How long after launch the owner makes the next launch's spare file: well past the launch work, so the
    /// block allocation never competes with it.
    public static let spareDelay: Duration = .seconds(90)

    /// The process kind the ring's header and file name carry.
    public let role: TraceRuntime.Role
    /// The folder of the ring files (created on the first file step).
    public let directory: String
    /// The ring's tables and chunks (trace.md "Sizes by role").
    public let sizes: TraceRing.Sizes
    /// The runtime's black-box ring, which every write of ``runtime`` lands in: the heap, then the file.
    public let ring: TraceRing
    /// The runtime that owns ``ring``.
    public let runtime: TraceRuntime
    /// The runtime's crash-key page (``TraceRuntime/attachCrashKeys(_:)``): the heap, mirrored into its file.
    public let crashKeys: CrashKeyPage
    /// The pid in the file names.
    public let pid: UInt32
    /// The fixed names a recording ring's name table starts with, as the black box's did.
    private let catalog: [TraceRing.CatalogName]
    /// 1 while a ``prepareRecording()`` maps the recording ring: one mapping per process, never two.
    private let preparingRecording = Atomic<UInt64>(0)

    /// Starts the black box on the heap, attaches it to `runtime` and turns on the black-box categories. No
    /// file work. When `runtime` already has a black box, ``ring`` is that one (a runtime keeps its first).
    ///
    /// - Parameters:
    ///   - role: The process kind; it picks the sizes.
    ///   - directory: The folder of the ring files.
    ///   - runtime: The runtime that owns the ring and whose category flags the black box sets
    ///     (``TraceCategories/blackBox``).
    ///   - process: The header's process fields; the calling process by default.
    ///   - buildVersion: The header's build version (version and build number, at most 32 ASCII bytes).
    ///   - catalog: The fixed names written into the ring's name table before any record (the app passes
    ///     `SignpostName.traceCatalog`).
    ///   - clock: The trace clock that stamps the ring's start.
    public init(role: TraceRuntime.Role, directory: String, runtime: TraceRuntime,
                process: ProcessFacts = .current(), buildVersion: String = "",
                catalog: [TraceRing.CatalogName] = [], clock: TraceClock = TraceClock()) {
        self.role = role
        self.directory = directory
        let sizes = role.blackBoxSizes
        self.sizes = sizes
        pid = process.pid
        let categories = TraceCategories.blackBox
        let identity = TraceRing.Identity(
            pid: process.pid, role: role.ringRole, ringKind: 1, clockDomain: 1,
            startUptimeNanos: clock.nowNanos(),
            startUnixNanos: clock_gettime_nsec_np(CLOCK_REALTIME),
            startContinuousNanos: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
            processStartUnixMicros: process.processStartUnixMicros,
            bootSessionUUID: process.bootSessionUUID, buildUUID: process.buildUUID,
            buildVersion: buildVersion, categories: categories.rawValue)
        self.runtime = runtime
        self.catalog = catalog
        ring = Self.attachedRing(of: runtime) { TraceRing(sizes: sizes, identity: identity, catalog: catalog) }
        crashKeys = Self.attachedCrashKeys(of: runtime) {
            CrashKeyPage(identity: .init(pid: process.pid, role: role.ringRole, buildUUID: process.buildUUID,
                                         processStartUnixMicros: process.processStartUnixMicros,
                                         startUptimeNanos: identity.startUptimeNanos))
        }
        runtime.setCategories(categories)
    }

    /// The crash-key page `runtime` writes to: the one attached already, else `make()`'s, attached now.
    private static func attachedCrashKeys(of runtime: TraceRuntime, making make: () -> CrashKeyPage) -> CrashKeyPage {
        if let attached = runtime.crashKeys { return attached }
        let made = make()
        runtime.attachCrashKeys(made)
        return runtime.crashKeys ?? made
    }

    /// The ring `runtime` writes to: the one attached already, else `make()`'s, attached now.
    private static func attachedRing(of runtime: TraceRuntime, making make: () -> TraceRing) -> TraceRing {
        if let attached = runtime.ring { return attached }
        let made = make()
        runtime.attach(made)
        return runtime.ring ?? made
    }

    /// The black-box file's path (it exists once ``adoptFile()`` succeeded).
    public var filePath: String {
        directory + "/" + TraceRingFile.fileName(role: role.ringRole, pid: pid)
    }

    /// Moves the ring from the heap into its black-box file (``TraceRingFile/adopt(_:directory:)``): rename the
    /// spare or create the file, map it, copy, swap; then the crash-key page (``CrashKeyPage/adopt(directory:)``).
    /// Blocking file work: BackgroundWork `.files` only. On a failure the ring or the page keeps writing to the
    /// heap and the failure is counted (the ring's counters, ``CrashKeyPage/adoptFailures``).
    ///
    /// - Returns: The mapped file, or nil when the ring stays on the heap.
    @discardableResult
    public func adoptFile() -> TraceRingFile? {
        assertBlockingAllowed(.fileIO)
        guard Self.makeDirectory(directory) else { return nil }
        let file = TraceRingFile.adopt(ring, directory: directory)
        // The copied header holds the categories of the copy; a change during the copy went to the heap.
        if file != nil { ring.mirrorCategories(runtime.categoryMask) }
        crashKeys.adopt(directory: directory)
        return file
    }

    /// Makes the role's spare file for the next launch (``TraceRingFile/prepareSpare(directory:role:sizes:)``).
    /// Blocking file work: BackgroundWork `.files` at a low priority, ``spareDelay`` after launch.
    ///
    /// - Returns: Whether a spare of the black box's size is ready.
    @discardableResult
    public func prepareSpare() -> Bool {
        assertBlockingAllowed(.fileIO)
        guard Self.makeDirectory(directory) else { return false }
        return TraceRingFile.prepareSpare(directory: directory, role: role.ringRole, sizes: sizes)
    }

    /// The recording ring's file (it exists once ``prepareRecording()`` succeeded).
    public var recordingPath: String {
        directory + "/" + TraceRingFile.recordingName(role: role.ringRole, pid: pid)
    }

    /// Maps the role's recording ring (``recordingPath``, ``TraceRuntime/Role/recordingSizes``) and attaches it
    /// to ``ring``, so ``TraceRuntime/startRecording(_:)`` only swaps the active ring and touches no disk
    /// (Rust's `Tracer::prepare_recording`). The ring is mapped once and never unmapped; a later call returns
    /// at once. Blocking file work: BackgroundWork `.files` only.
    ///
    /// - Returns: Whether ``ring`` has its recording ring (false also while another call still maps it).
    @discardableResult
    public func prepareRecording() -> Bool {
        if ring.recordingRing != nil { return true }
        guard preparingRecording.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged else {
            return ring.recordingRing != nil
        }
        defer { preparingRecording.store(0, ordering: .releasing) }
        assertBlockingAllowed(.fileIO)
        guard ring.recordingRing == nil else { return true }
        guard Self.makeDirectory(directory) else { return false }
        let layout = TraceRingLayout(role.recordingSizes)
        let path = recordingPath
        guard let mapping = TraceRingFile.mapRecording(path: path, byteCount: layout.totalBytes) else { return false }
        let storage = TraceRingStorage(base: mapping, layout: layout)
        var identity = ring.identity
        identity.ringKind = 2
        identity.categories = runtime.categoryMask
        storage.initialize(identity: identity, catalog: catalog)
        return ring.attachRecording(storage, path: path)
    }

    /// Deletes the black boxes of dead processes in ``directory`` (``TraceRingCleanup``); this process's
    /// file is live, so it stays. Blocking file work: BackgroundWork `.files`.
    ///
    /// - Parameter now: The wall clock in nanoseconds since 1970; the current time by default.
    /// - Returns: What was kept and what was deleted.
    @discardableResult
    public func cleanUp(now: UInt64? = nil) -> TraceRingCleanup.Report {
        assertBlockingAllowed(.fileIO)
        var cleanup = TraceRingCleanup(directory: directory)
        if let now { cleanup.nowUnixNanos = { now } }
        return cleanup.run()
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
}

extension TraceBlackBox {
    /// The process fields of a ring header that the kernel and the loaded image know (trace.md "Header").
    /// Reading them is two system calls and a walk of the main image's load commands in memory, no file.
    public struct ProcessFacts: Sendable, Equatable {
        /// The writing process.
        public var pid: UInt32
        /// The kernel's start time of ``pid`` in microseconds since 1970; with `kill(pid, 0)`, cleanup tells a
        /// reused pid. 0 when unknown.
        public var processStartUnixMicros: UInt64
        /// `kern.bootsessionuuid` as 16 bytes; empty when unknown.
        public var bootSessionUUID: [UInt8]
        /// The main image's `LC_UUID`; empty when it has none.
        public var buildUUID: [UInt8]

        /// Facts as given (tests and tools).
        public init(pid: UInt32, processStartUnixMicros: UInt64 = 0, bootSessionUUID: [UInt8] = [], buildUUID: [UInt8] = []) {
            self.pid = pid
            self.processStartUnixMicros = processStartUnixMicros
            self.bootSessionUUID = bootSessionUUID
            self.buildUUID = buildUUID
        }

        /// The calling process's facts.
        public static func current() -> ProcessFacts {
            let pid = getpid()
            return ProcessFacts(pid: UInt32(bitPattern: pid),
                                processStartUnixMicros: TraceRingCleanup.processStartUnixMicros(pid: pid),
                                bootSessionUUID: bootSessionUUID(), buildUUID: mainImageUUID())
        }

        /// `kern.bootsessionuuid` (`8-4-4-4-12` hex) as 16 bytes.
        private static func bootSessionUUID() -> [UInt8] {
            var buffer = [CChar](repeating: 0, count: 64)
            var length = buffer.count
            guard blockingSysctlByName("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 else { return [] }
            var bytes: [UInt8] = []
            var high: UInt8?
            for character in buffer.prefix(while: { $0 != 0 }) where character != CChar(UInt8(ascii: "-")) {
                guard let digit = hexDigit(UInt8(bitPattern: character)) else { return [] }
                if let pending = high {
                    bytes.append(pending << 4 | digit)
                    high = nil
                } else {
                    high = digit
                }
            }
            return bytes.count == 16 && high == nil ? bytes : []
        }

        private static func hexDigit(_ character: UInt8) -> UInt8? {
            switch character {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): character - UInt8(ascii: "0")
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
            default: nil
            }
        }

        /// The `LC_UUID` of the main executable (image 0, which dyld keeps mapped for the process's life).
        private static func mainImageUUID() -> [UInt8] {
            guard let header = _dyld_get_image_header(0), header.pointee.magic == UInt32(MH_MAGIC_64) else { return [] }
            let commandCount = UnsafeRawPointer(header).loadUnaligned(as: mach_header_64.self).ncmds
            var command = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
            for _ in 0 ..< commandCount {
                let load = command.loadUnaligned(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    let uuid = command.loadUnaligned(as: uuid_command.self).uuid
                    return withUnsafeBytes(of: uuid) { Array($0) }
                }
                guard load.cmdsize >= UInt32(MemoryLayout<load_command>.size) else { return [] }
                command += Int(load.cmdsize)
            }
            return []
        }
    }
}

extension TraceRuntime.Role {
    /// The black box's tables and chunks for this kind of process (trace.md "Sizes by role"; Rust's
    /// `Role::blackbox_sizes`). The CLI has no row there and takes the holder's.
    public var blackBoxSizes: TraceRing.Sizes {
        let row = sizeRow
        return TraceRing.Sizes(nameCapacity: row.names, threadCapacity: row.threads, chunkCount: row.blackBoxChunks)
    }

    /// A recording ring's tables and chunks for this kind of process (trace.md "Sizes by role"; Rust's
    /// `Role::recording_sizes`): the same tables as the black box, more chunks.
    public var recordingSizes: TraceRing.Sizes {
        let row = sizeRow
        return TraceRing.Sizes(nameCapacity: row.names, threadCapacity: row.threads, chunkCount: row.recordingChunks)
    }

    private var sizeRow: (names: Int, threads: Int, blackBoxChunks: Int, recordingChunks: Int) {
        switch self {
        case .app, .daemon: (4096, 2048, 512, 32768)
        case .chromiumHost: (4096, 2048, 512, 8192)
        case .holder, .acpmux, .cli, .agentHost, .browserHost: (2048, 512, 256, 8192)
        case .terminalHost, .appHost: (1024, 256, 64, 512)
        }
    }

    /// The ring's spelling of this role (the same header value).
    var ringRole: TraceRing.Role {
        switch self {
        case .app: .app
        case .daemon: .daemon
        case .holder: .holder
        case .terminalHost: .terminalHost
        case .acpmux: .acpmux
        case .chromiumHost: .chromiumHost
        case .cli: .cli
        case .agentHost: .agentHost
        case .appHost: .appHost
        case .browserHost: .browserHost
        }
    }
}

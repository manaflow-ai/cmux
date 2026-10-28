import CmuxNextCompat
import Darwin

/// Deletes the black-box ring files of processes that ended, as plans/cmux-next/trace.md ("Sizes by role")
/// specifies: a black box whose process has been dead for more than ``maxAge`` goes; then the longest-dead ones
/// go until the dead processes' black boxes take at most ``deadByteCap``. A live process's ring is never
/// deleted, and recording rings are not touched (they are under the `trace.start` cap). Rust's
/// `cmux_trace::cleanup` (task 095) follows the same rule for the daemon's directory.
///
/// The age counts from the first cleanup that found the process dead, not from the ring's start or its file's
/// mtime: records go through a `MAP_SHARED` mapping, which does not reliably move the mtime, so the black box of
/// a session that ran for days and then crashed must not read as days old at the next launch. That cleanup
/// creates `<ring>.dead` (``deadMarkSuffix``) with its own wall clock as the mtime.
///
/// A process's crash-key page (`<role>-<pid>.crashkeys`, ``CrashKeyPage``) goes with its black box, and a page
/// whose black box is gone goes once its process is dead.
///
/// A process is live when `kill(pid, 0)` finds it and its kernel start time is the one in the ring's header
/// (`process_start_unix_us`), so a reused pid does not keep an old ring. Chrome cleans its metrics directory the
/// same way, by age and a size cap (`base::GlobalHistogramAllocator`'s upload directory,
/// components/metrics/file_metrics_provider.cc).
///
/// Blocking file work: BackgroundWork `.files` only.
///
/// ```swift
/// let report = TraceRingCleanup(directory: path).run()
/// ```
public struct TraceRingCleanup: Sendable {
    /// A black box whose process has been dead for longer than this is deleted.
    public static let maxAge: Duration = .seconds(3 * 24 * 3600)
    /// The most bytes the dead processes' black boxes keep after the age rule.
    public static let deadByteCap = 16 * 1024 * 1024
    /// The file name suffix of a black-box ring (``TraceRingFile/fileName(role:pid:)``).
    static let blackBoxSuffix = ".blackbox.cmxtrace"
    /// The suffix of a spare file still being built (``TraceRingFile/prepareSpare(directory:role:sizes:)``).
    static let buildingSuffix = ".tmp"
    /// The suffix of the marker whose mtime is when a cleanup first found a black box's process dead.
    static let deadMarkSuffix = ".dead"
    /// The file name suffix of a crash-key page (``CrashKeyPage/fileName(role:pid:)``).
    static let crashKeysSuffix = ".crashkeys"

    /// The folder of the ring files.
    public let directory: String
    /// Whether process `pid`, started at `startMicros` (0: unknown), still runs.
    public var isAlive: @Sendable (_ pid: Int32, _ startMicros: UInt64) -> Bool = { TraceRingCleanup.processIsAlive(pid: $0, startMicros: $1) }
    /// The wall clock in nanoseconds since 1970.
    public var nowUnixNanos: @Sendable () -> UInt64 = { TraceRingCleanup.wallClockNanos() }

    /// A cleanup of `directory` with the system's process table and clock.
    public init(directory: String) {
        self.directory = directory
    }

    /// What one cleanup kept and deleted (file names).
    public struct Report: Sendable, Equatable {
        /// Black boxes of live processes.
        public var live: [String] = []
        /// Black boxes of dead processes that stayed (dead for less than ``TraceRingCleanup/maxAge``, under the cap).
        public var keptDead: [String] = []
        /// Files deleted: long-dead or over-cap black boxes and abandoned spare builds (not their markers).
        public var deleted: [String] = []
    }

    /// Runs the cleanup once.
    ///
    /// - Returns: What it kept and deleted.
    @discardableResult
    public func run() -> Report {
        var report = Report()
        let now = nowUnixNanos()
        let maxAgeNanos = UInt64(Self.maxAge.components.seconds) * 1_000_000_000
        let names = fileNames()
        let present = Set(names)
        var dead: [Ring] = []
        for name in names {
            if name.hasSuffix(Self.buildingSuffix) {
                if let pid = Self.builderPID(name), !isAlive(pid, 0), remove(name) { report.deleted.append(name) }
                continue
            }
            guard name.hasSuffix(Self.blackBoxSuffix), var ring = read(name) else { continue }
            if isAlive(ring.pid, ring.startMicros) {
                // A marker left by an earlier process with this pid would date the new one's death too early.
                if present.contains(name + Self.deadMarkSuffix) { _ = remove(name + Self.deadMarkSuffix) }
                report.live.append(name)
                continue
            }
            ring.deadSinceUnixNanos = deadSince(name, now: now)
            if now > ring.deadSinceUnixNanos, now - ring.deadSinceUnixNanos > maxAgeNanos {
                if delete(name) { report.deleted.append(name) }
            } else {
                dead.append(ring)
            }
        }
        // A marker whose ring is gone (deleted above, or by hand).
        for marker in names where marker.hasSuffix(Self.blackBoxSuffix + Self.deadMarkSuffix) {
            if !present.contains(String(marker.dropLast(Self.deadMarkSuffix.count))) { _ = remove(marker) }
        }
        // A page whose black box never existed (its adoption failed) or was deleted by hand.
        for page in names where page.hasSuffix(Self.crashKeysSuffix) {
            let stem = page.dropLast(Self.crashKeysSuffix.count)
            guard !present.contains(String(stem) + Self.blackBoxSuffix), let dash = stem.lastIndex(of: "-"),
                  let pid = Int32(stem[stem.index(after: dash)...]), !isAlive(pid, 0) else { continue }
            if remove(page) { report.deleted.append(page) }
        }
        // The cap: the longest-dead rings go first.
        dead.sort { ($0.deadSinceUnixNanos, $0.startUnixNanos, $0.name) < ($1.deadSinceUnixNanos, $1.startUnixNanos, $1.name) }
        var bytes = dead.reduce(0) { $0 + $1.bytes }
        for ring in dead {
            if bytes > Self.deadByteCap, delete(ring.name) {
                bytes -= ring.bytes
                report.deleted.append(ring.name)
            } else {
                report.keptDead.append(ring.name)
            }
        }
        return report
    }

    /// When a cleanup first found the process of black box `name` dead: its marker's mtime, or `now` once this
    /// call made the marker with that mtime. When no marker can be made the answer is `now`, so the ring stays
    /// until a later cleanup marks it.
    private func deadSince(_ name: String, now: UInt64) -> UInt64 {
        let marker = directory + "/" + name + Self.deadMarkSuffix
        return blockingCall(.fileIO) {
            var info = stat()
            if lstat(marker, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                return UInt64(max(0, info.st_mtimespec.tv_sec)) * 1_000_000_000 + UInt64(max(0, info.st_mtimespec.tv_nsec))
            }
            let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return now }
            defer { close(descriptor) }
            let stamp = timespec(tv_sec: Int(now / 1_000_000_000), tv_nsec: Int(now % 1_000_000_000))
            var times = [stamp, stamp]
            _ = futimens(descriptor, &times)
            return now
        }
    }

    /// Deletes black box `name`, its dead marker and its process's crash-key page; true when the ring went.
    private func delete(_ name: String) -> Bool {
        guard remove(name) else { return false }
        _ = remove(name + Self.deadMarkSuffix)
        _ = remove(String(name.dropLast(Self.blackBoxSuffix.count)) + Self.crashKeysSuffix)
        return true
    }

    // MARK: - Files

    /// A black-box file: its process (from the header, else the name), its start and its size.
    private struct Ring {
        var name: String
        var pid: Int32
        var startMicros: UInt64
        /// The ring's start (header `start_unix_ns`; the file's mtime for a file that is not a v1 ring): the
        /// cap's tie-break only, never its age.
        var startUnixNanos: UInt64
        var bytes: Int
        /// When a cleanup first found its process dead (``deadSince(_:now:)``).
        var deadSinceUnixNanos: UInt64 = 0
    }

    private func fileNames() -> [String] {
        return blockingCall(.fileIO) {
            guard let stream = opendir(directory) else { return [] }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = Self.name(of: entry)
                if name != ".", name != ".." { names.append(name) }
            }
            return names
        }
    }

    /// The name of one `readdir` record, read from the record's own bytes: a record is `d_reclen` bytes long,
    /// not `sizeof(dirent)`, so the struct and its 1024-byte `d_name` are never copied (as `FolderListing` reads them).
    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        let raw = UnsafeRawPointer(entry)
        let length = Int(raw.loadUnaligned(fromByteOffset: nameLengthOffset, as: UInt16.self))
        return String(decoding: UnsafeRawBufferPointer(start: raw + nameOffset, count: length), as: UTF8.self)
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) ?? 21
    private static let nameLengthOffset = MemoryLayout<dirent>.offset(of: \dirent.d_namlen) ?? 18

    /// The ring's header fields, read with one `pread`; a file that is not a v1 ring takes its pid from its name
    /// and its start from the file system.
    private func read(_ name: String) -> Ring? {
        let path = directory + "/" + name
        return blockingCall(.fileIO) {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            let modified = UInt64(max(0, info.st_mtimespec.tv_sec)) * 1_000_000_000 + UInt64(max(0, info.st_mtimespec.tv_nsec))
            var header = [UInt8](repeating: 0, count: TraceRing.headerBytes)
            let read = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
            func word(_ offset: Int) -> UInt64 {
                (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(header[offset + $1]) << (8 * UInt64($1)) }
            }
            if read == TraceRing.headerBytes, word(0) == TraceRing.magic {
                let pid = Int32(bitPattern: UInt32(truncatingIfNeeded: word(16)))
                return Ring(name: name, pid: pid, startMicros: word(40), startUnixNanos: word(32), bytes: Int(info.st_size))
            }
            guard let pid = Self.namePID(name) else { return nil }
            return Ring(name: name, pid: pid, startMicros: 0, startUnixNanos: modified, bytes: Int(info.st_size))
        }
    }

    private func remove(_ name: String) -> Bool {
        blockingCall(.fileIO) { unlink(directory + "/" + name) == 0 }
    }

    /// The pid of `<role>-<pid>.blackbox.cmxtrace`.
    static func namePID(_ name: String) -> Int32? {
        guard name.hasSuffix(blackBoxSuffix) else { return nil }
        let stem = name.dropLast(blackBoxSuffix.count)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        return Int32(stem[stem.index(after: dash)...])
    }

    /// The pid of a spare being built, `<role>.spare.cmxtrace.<pid>.tmp`.
    static func builderPID(_ name: String) -> Int32? {
        let stem = name.dropLast(buildingSuffix.count)
        guard stem.contains(".spare.cmxtrace."), let dot = stem.lastIndex(of: ".") else { return nil }
        return Int32(stem[stem.index(after: dot)...])
    }

    // MARK: - System

    /// `kill(pid, 0)` finds the process (EPERM: it exists under another user), and when `startMicros` is known,
    /// the process with that pid started then. A start time that cannot be read counts as a match.
    public static func processIsAlive(pid: Int32, startMicros: UInt64) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard startMicros != 0 else { return true }
        let current = processStartUnixMicros(pid: pid)
        return current == 0 || current == startMicros
    }

    /// The kernel's start time of `pid` in microseconds since 1970 (`proc_pidinfo` `PROC_PIDTBSDINFO`); 0 when
    /// it cannot be read.
    public static func processStartUnixMicros(pid: Int32) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    static func wallClockNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_REALTIME)
    }
}

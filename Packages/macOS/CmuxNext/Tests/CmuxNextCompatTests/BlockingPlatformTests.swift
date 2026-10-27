@testable import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The detector's platform parts (p15-oracle-122): what counts as the main thread, the queue label the pool test
/// reads, the detector's clock, the POSIX and spawn seams, and the Linux answers of the Mach-only parts. Each part
/// runs on macOS and on Linux; the Linux-only cases say so.
@Suite(.serialized)
struct BlockingPlatformTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// A main-actor job is the main thread to the detector, also on Linux, where `dispatch_main` (swift-testing's)
    /// runs the main queue's jobs off the process's main thread.
    @MainActor @Test func aMainActorJobIsTheMainThread() {
        #expect(blockingOnMainThread())
        #expect(BlockingContext.current() == .main)
    }

    @Test func aNamedSerialQueueIsNotTheMainThreadAndReadsItsLabel() async {
        let queue = DispatchQueue(label: "com.cmuxterm.tests.platform-label")
        let seen = await onQueue(queue) { (blockingOnMainThread(), BlockingContext.callingQueueLabel(), BlockingContext.current()) }
        #expect(!seen.0)
        #expect(seen.1 == "com.cmuxterm.tests.platform-label")
        #expect(seen.2 == .dedicated)
    }

    @Test func aGlobalQueueIsThePoolOnEveryPlatform() async {
        #expect(await onQueue(.global(qos: .utility)) { BlockingContext.current() } == .pool)
    }

    /// A POSIX seam on the main thread records one site of its kind at its caller; the same calls on a named queue
    /// record none. Linux reaches Glibc's calls through the same unqualified names.
    @MainActor @Test func thePosixSeamsRecordOnTheMainThreadOnly() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-platform-\(UUID().uuidString)").path
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) { callPosixSeams(path) }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.fileIO, .fsMetadata, .fsMetadata])

        let offMain = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(DispatchQueue(label: "com.cmuxterm.tests.platform-posix")) {
            BlockingViolationTable.$scoped.withValue(offMain) { callPosixSeams(path) }
        }
        await offMain.flush()
        #expect(BlockingDetector(table: offMain).sites.isEmpty)
    }

    /// The table's default clock is monotonic and moves with real time.
    @Test func theDefaultClockIsMonotonic() {
        let before = BlockingViolationTable.systemUptimeNanos()
        usleep(2_000)
        let after = BlockingViolationTable.systemUptimeNanos()
        #expect(after >= before + 2_000_000)
    }
    #endif

    /// The priority form of the spawn seam with no attributes of the caller's makes its own (Darwin's opaque
    /// pointer, Glibc's struct) and starts the child.
    @Test(arguments: MayBlockPriority.allCases)
    func theSpawnSeamStartsAChildAtEachPriority(priority: MayBlockPriority) async {
        let status = await onQueue(DispatchQueue(label: "com.cmuxterm.tests.platform-spawn")) { spawnTrue(priority) }
        #expect(status == 0)
    }

    #if !canImport(Darwin)
    /// Linux has no Mach task role or `PRIO_DARWIN_BG`: a role change succeeds and does nothing and a read is nil,
    /// as in `cmux_threads::process_role`'s non-Apple `sys`.
    @Test func aProcessRoleIsANoOpOnLinux() throws {
        try ProcessRole.applyDefault()
        try ProcessRole.backgroundSuppressed.applySuppression(toChild: getpid())
        #expect(ProcessRole.currentTaskRole() == nil)
        #expect(ProcessRole.darwinBackground() == nil)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Linux libdispatch labels a thread no queue runs with the overcommit root label: it is dedicated, as a cmux
    /// `Thread` is; a root queue's worker and Swift's global executor are the pool.
    @Test(arguments: [
        ("com.apple.root.default-qos.overcommit", false),
        ("com.apple.root.default-qos", true),
        ("Swift global concurrent queue", true),
    ])
    func linuxPoolLabels(label: String, isPool: Bool) {
        #expect(label.withCString { BlockingContext.isPoolLabel($0) } == isPool)
    }

    @Test func aThreadIsDedicatedOnLinux() async {
        let context = await withCheckedContinuation { (done: CheckedContinuation<BlockingContext, Never>) in
            Thread { done.resume(returning: BlockingContext.current()) }.start()
        }
        #expect(context == .dedicated)
    }

    @Test func detachedTasksRunOnThePool() async {
        #expect(await Task.detached { BlockingContext.current() }.value == .pool)
    }

    /// The Mach-O frame reader has no Linux twin: a Linux report names its site with no frames.
    @Test func aLinuxReportHasNoFrames() {
        var call = BlockingPendingCall(kind: .fileIO, site: 0, fileID: #fileID, line: #line)
        call.captureStack()
        var resolver = BlockingFrameResolver()
        #expect(call.stack.isEmpty)
        #expect(resolver.frames([1, 2, 3]).isEmpty)
    }
    #endif
    #endif
}

/// Runs `body` on `queue` and returns its result.
private nonisolated func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        queue.async { done.resume(returning: body()) }
    }
}

/// Creates, stats and removes the file at `path` through the checked POSIX seams: one file-io and two fs-metadata
/// sites.
private nonisolated func callPosixSeams(_ path: String) {
    // SAFETY: `path` is bridged to a NUL-terminated C string for each call, and `info` is a local stat fills.
    let descriptor = unsafe blockingOpen(path, O_CREAT | O_WRONLY, 0o600)
    if descriptor >= 0 { close(descriptor) }
    var info = stat()
    _ = unsafe blockingStat(path, &info)
    _ = unsafe blockingUnlink(path)
}

/// Spawns `/bin/true` through the priority form of the spawn seam with no attributes, then reaps it.
///
/// - Returns: The spawn's status (0 when it started) or -1 when its arguments could not be made, and the child's
///   exit status folded in: a child that did not exit 0 makes it nonzero.
private nonisolated func spawnTrue(_ priority: MayBlockPriority) -> Int32 {
    var pid = pid_t()
    // SAFETY: the argument list lives for the closure, posix_spawn copies it into the child before it returns, and
    // `pid` is a local the seam writes once.
    let spawned = unsafe withCStringList(["/bin/true"]) { argv in
        unsafe blockingPosixSpawn(&pid, "/bin/true", nil, nil, argv, nil, priority: priority)
    } ?? -1
    guard spawned == 0 else { return spawned }
    var status: Int32 = 0
    // SAFETY: `status` is a local waitpid writes once.
    _ = unsafe waitpid(pid, &status, 0)
    return status
}

@testable import CmuxNextCompat
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import LocalAuthentication
import SQLite3
import Testing

/// The checked seams over POSIX file calls, `waitpid`, FileHandle opens and seeks, ImageIO file I/O, SQLite,
/// kernel and directory queries and `LAContext.canEvaluatePolicy`: on the main thread each one records exactly
/// one site at its caller's line with its kind; on a named serial queue none records. Each test binds its own
/// table (``BlockingViolationTable/scoped``) and works in its own temporary directory, which it removes; the
/// only child is `/usr/bin/true`, and the policy check asks for biometrics, which never shows a prompt.
@Suite(.serialized)
struct BlockingPosixSeamTests {
    /// The names the debug log and the hang reports use never change.
    @Test func theNewKindsKeepTheirNames() {
        #expect(BlockingKind.fsMetadata.rawValue == "fs-metadata")
        #expect(BlockingKind.sqlite.rawValue == "sqlite")
        #expect(BlockingKind.processReap.rawValue == "process-reap")
        #expect(BlockingKind.systemQuery.rawValue == "system-query")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Each seam runs its call through `blockingCall`, so its site carries the call's wall time (the injected
    /// clock measures every timed call as ``SeamTickClock/tick``).
    @MainActor @Test func eachSeamOnTheMainThreadRecordsOneSiteAtItsCaller() async throws {
        let clock = SeamTickClock()
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let expected = try BlockingViolationTable.$scoped.withValue(table) { try callEachPosixSeam() }
        await table.flush()

        #expect(expected.count == Self.seamCalls)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(BlockingDetector(table: table).sites == expected)
    }

    @MainActor @Test func theSameSeamsOnANamedSerialQueueRecordNothing() async throws {
        let table = BlockingViolationTable(mode: .record)
        let (onMain, called) = try await callEachPosixSeamOnNamedQueue(table)
        await table.flush()

        #expect(!onMain)
        #expect(called == Self.seamCalls)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The seam calls `callEachPosixSeam` makes: 34 seams, plus the spawn of the child it reaps and the two
    /// extra unlinks that clean up.
    private static let seamCalls = 37
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Calls every seam of this task once (and a few twice to clean up), on the caller's thread, in a new
/// temporary directory, and returns the site each call records on the main thread (its kind, this file's line
/// of the call and one tick of wall time).
private nonisolated func callEachPosixSeam() throws -> [BlockingSite] {
    var expected: [BlockingSite] = []
    func seam(_ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ call: () throws -> Void) rethrows {
        expected.append(BlockingSite(kind: kind, location: "\(fileID):\(line)", count: 1,
                                     totalNanos: SeamTickClock.tick, maxNanos: SeamTickClock.tick))
        try call()
    }

    let directory = NSTemporaryDirectory() + "cmux-posix-seams-\(UUID().uuidString)"
    var status: Int32 = -1
    seam(.fsMetadata) { status = blockingMkdir(directory, 0o700) }
    try #require(status == 0)

    // POSIX file calls on one file.
    let file = directory + "/file"
    var descriptor: Int32 = -1
    seam(.fileIO) { descriptor = blockingOpen(file, O_RDWR | O_CREAT, 0o600) }
    try #require(descriptor >= 0)
    var byte: UInt8 = 7
    seam(.fileIO) { _ = blockingPwrite(descriptor, &byte, 1, 0) }
    seam(.fileIO) { _ = blockingPread(descriptor, &byte, 1, 0) }
    seam(.fileIO) { _ = blockingFsync(descriptor) }
    seam(.syncWait) { _ = blockingFlock(descriptor, LOCK_EX | LOCK_NB) }
    close(descriptor)
    var info = stat()
    seam(.fsMetadata) { _ = blockingStat(file, &info) }
    seam(.fsMetadata) { _ = blockingLstat(file, &info) }
    seam(.fsMetadata) { _ = blockingAccess(file, R_OK) }
    seam(.fsMetadata) { free(blockingRealpath(file, nil)) }
    let moved = directory + "/moved"
    seam(.fsMetadata) { _ = blockingRename(file, moved) }

    // FileHandle opens, seeks and flushes on the moved file.
    let movedURL = URL(fileURLWithPath: moved)
    try seam(.fileIO) { _ = try FileHandle.blockingForReading(from: movedURL) }
    try seam(.fileIO) { _ = try FileHandle.blockingForWriting(to: movedURL) }
    var handle: FileHandle?
    try seam(.fileIO) { handle = try FileHandle.blockingForUpdating(movedURL) }
    let updating = try #require(handle)
    try seam(.fileIO) { _ = try updating.blockingSeekToEnd() }
    try seam(.fileIO) { try updating.blockingSeek(toOffset: 0) }
    try seam(.fileIO) { try updating.blockingSynchronize() }
    try updating.close()
    seam(.fsMetadata) { _ = blockingUnlink(moved) }

    // ImageIO: write a 1x1 PNG, then open it.
    let imageURL = URL(fileURLWithPath: directory + "/image.png") as CFURL
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    let image = try #require(context?.makeImage())
    var destination: CGImageDestination?
    seam(.fileIO) { destination = blockingImageDestination(url: imageURL, type: "public.png" as CFString, count: 1) }
    let writer = try #require(destination)
    CGImageDestinationAddImage(writer, image, nil)
    var written = false
    seam(.fileIO) { written = blockingImageDestinationFinalize(writer) }
    #expect(written)
    var source: CGImageSource?
    seam(.fileIO) { source = blockingImageSource(url: imageURL) }
    #expect(source.map(CGImageSourceGetCount) == 1)
    seam(.fsMetadata) { _ = blockingUnlink(directory + "/image.png") }

    // SQLite on a new database.
    let databasePath = directory + "/db.sqlite"
    var database: OpaquePointer?
    seam(.sqlite) { status = blockingSQLiteOpen(databasePath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) }
    #expect(status == SQLITE_OK)
    seam(.sqlite) { status = blockingSQLiteExec(database, "CREATE TABLE t(x)") }
    #expect(status == SQLITE_OK)
    var statement: OpaquePointer?
    seam(.sqlite) { status = blockingSQLitePrepare(database, "SELECT count(*) FROM t", -1, &statement, nil) }
    #expect(status == SQLITE_OK)
    seam(.sqlite) { status = blockingSQLiteStep(statement) }
    #expect(status == SQLITE_ROW)
    sqlite3_finalize(statement)
    seam(.sqlite) { status = blockingSQLiteClose(database) }
    #expect(status == SQLITE_OK)
    seam(.fsMetadata) { _ = blockingUnlink(databasePath) }
    seam(.fsMetadata) { _ = blockingRmdir(directory) }

    // A child, reaped.
    var pid: pid_t = 0
    let path = strdup("/usr/bin/true")
    defer { free(path) }
    let argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
    seam(.processSpawn) { status = blockingPosixSpawn(&pid, "/usr/bin/true", nil, nil, argv, environ) }
    try #require(status == 0)
    var exitStatus: Int32 = 0
    seam(.processReap) { _ = blockingWaitpid(pid, &exitStatus, 0) }

    // Kernel and directory queries about this process and user.
    var mib: [Int32] = [CTL_KERN, KERN_OSRELEASE]
    let mibCount = u_int(mib.count)
    var size = 0
    seam(.systemQuery) { _ = blockingSysctl(&mib, mibCount, nil, &size, nil, 0) }
    var processors: Int32 = 0
    var processorsSize = MemoryLayout<Int32>.size
    seam(.systemQuery) { _ = blockingSysctlByName("hw.ncpu", &processors, &processorsSize, nil, 0) }
    var bsdInfo = proc_bsdinfo()
    seam(.systemQuery) { _ = blockingProcPidInfo(getpid(), PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) }
    seam(.systemQuery) { _ = blockingGetpwuid(getuid()) }
    seam(.systemQuery) { _ = blockingGetpwnam("root") }

    seam(.ipcReply) { _ = LAContext().blockingCanEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics) }
    return expected
}

/// A clock that moves ``tick`` nanoseconds per read, so each timed call (two reads) measures ``tick``.
private nonisolated final class SeamTickClock: Sendable {
    static let tick: UInt64 = 1_000
    private let now = Mutex(UInt64(0))

    func read() -> UInt64 {
        now.withLock { now in
            now += Self.tick
            return now
        }
    }
}

/// The same calls on a named serial queue, a context where blocking is allowed (not the cooperative pool or a
/// GCD root queue), with `table` bound there. Returns whether they ran on the main thread and how many seams
/// they called.
private nonisolated func callEachPosixSeamOnNamedQueue(_ table: BlockingViolationTable) async throws -> (Bool, Int) {
    let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-posix-seams")
    return try await withCheckedThrowingContinuation { continuation in
        queue.async {
            continuation.resume(with: Result {
                try BlockingViolationTable.$scoped.withValue(table) { (pthread_main_np() != 0, try callEachPosixSeam().count) }
            })
        }
    }
}
#endif

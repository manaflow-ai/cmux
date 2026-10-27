#if canImport(ImageIO)
@testable import CmuxNextCompat
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import LocalAuthentication
import SQLite3
import Testing

/// The checked seams over POSIX file calls, `waitpid` and `waitid`, FileHandle opens and seeks, ImageIO file I/O
/// and decoding, SQLite, kernel, process and directory queries and `LAContext.canEvaluatePolicy`: on the main
/// thread each one records exactly one site at its caller's line with its kind; on a named serial queue none
/// records. Each test binds its own table (``BlockingViolationTable/scoped``) and works in its own temporary
/// directory, which it removes; the only child is `/usr/bin/true`, and the policy check asks for biometrics, which never shows a prompt.
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

    /// The seam calls `callEachPosixSeam` makes: 47 seams, plus the spawn of the child it reaps, the second
    /// SQLite open (the backup's copy) and the three extra unlinks that clean up.
    private static let seamCalls = 52
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
    seam(.fileIO) { _ = blockingFlock(descriptor, LOCK_EX | LOCK_NB) }
    seam(.fileIO) { _ = blockingFtruncate(descriptor, 1) }
    var vnodeInfo = vnode_fdinfowithpath()
    let vnodeInfoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    seam(.systemQuery) { _ = blockingProcPidFDInfo(getpid(), descriptor, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, vnodeInfoSize) }
    close(descriptor)
    var info = stat()
    seam(.fsMetadata) { _ = blockingStat(file, &info) }
    seam(.fsMetadata) { _ = blockingLstat(file, &info) }
    seam(.fsMetadata) { _ = blockingAccess(file, R_OK) }
    seam(.fsMetadata) { _ = blockingChmod(file, 0o600) }
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
    let reader = try #require(source)
    var imageCount = 0
    seam(.fileIO) { imageCount = blockingImageSourceCount(reader) }
    #expect(imageCount == 1)
    seam(.fileIO) { _ = blockingImageSourceCopyProperties(reader, at: 0) }
    var decoded: CGImage?
    let decodeOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    seam(.fileIO) { decoded = blockingImageSourceCreateImage(reader, at: 0, options: decodeOptions as CFDictionary) }
    #expect(decoded?.width == 1)
    let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 1]
    seam(.fileIO) { _ = blockingImageSourceCreateThumbnail(reader, at: 0, options: thumbnailOptions as CFDictionary) }
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
    // Back it up into a second database.
    let copyPath = directory + "/copy.sqlite"
    var copy: OpaquePointer?
    seam(.sqlite) { status = blockingSQLiteOpen(copyPath, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) }
    #expect(status == SQLITE_OK)
    let backup = try #require(sqlite3_backup_init(copy, "main", database, "main"))
    seam(.sqlite) { status = blockingSQLiteBackupStep(backup, -1) }
    #expect(status == SQLITE_DONE)
    sqlite3_backup_finish(backup)
    seam(.sqlite) { status = blockingSQLiteCloseV2(copy) }
    #expect(status == SQLITE_OK)
    seam(.sqlite) { status = blockingSQLiteClose(database) }
    #expect(status == SQLITE_OK)
    seam(.fsMetadata) { _ = blockingUnlink(copyPath) }
    seam(.fsMetadata) { _ = blockingUnlink(databasePath) }
    seam(.fsMetadata) { _ = blockingRmdir(directory) }

    // A child, reaped.
    var pid: pid_t = 0
    let path = strdup("/usr/bin/true")
    defer { free(path) }
    let argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
    seam(.processSpawn) { status = blockingPosixSpawn(&pid, "/usr/bin/true", nil, nil, argv, environ) }
    try #require(status == 0)
    var childInfo = siginfo_t()
    seam(.processReap) { status = blockingWaitid(P_PID, id_t(pid), &childInfo, WEXITED | WNOWAIT) }
    #expect(status == 0)
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
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathBufferSize = UInt32(pathBuffer.count)
    seam(.systemQuery) { _ = blockingProcPidPath(getpid(), &pathBuffer, pathBufferSize) }
    seam(.systemQuery) { _ = blockingProcListPids(UInt32(PROC_UID_ONLY), getuid(), nil, 0) }
    let usage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<rusage_info_v4>.size,
                                                 alignment: MemoryLayout<rusage_info_v4>.alignment)
    defer { usage.deallocate() }
    let usageBuffer = usage.bindMemory(to: rusage_info_t?.self, capacity: 1)
    seam(.systemQuery) { _ = blockingProcPidRusage(getpid(), RUSAGE_INFO_V4, usageBuffer) }
    seam(.systemQuery) { _ = blockingGetpwuid(getuid()) }
    seam(.systemQuery) { _ = blockingGetpwnam("root") }

    seam(.systemCall) { _ = LAContext().blockingCanEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics) }
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
#endif

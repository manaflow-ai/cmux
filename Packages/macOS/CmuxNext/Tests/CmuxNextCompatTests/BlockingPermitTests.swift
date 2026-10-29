#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The compiler permit (plans/cmux-next/chrome-parity/p02-threads.md, task 111): a lane or allowance body gets a
/// ``BlockingPermit``, the seam overloads that take it run the same checked call, and the permit form of a read in
/// a lane body records nothing. The `noasync` diagnostic is checked by
/// scripts/cmux-next/check-blocking-permit-fixture.sh against CompileFailFixtures/BlockingPermitNoasync.swift (in no
/// target).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BlockingPermitTests {
    /// Acceptance: the permit form of a read in a runner body compiles and records 0 sites.
    @Test func aRunnerBodyGetsALanePermitAndItsReadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let url = try permitFixture("permit-read")
        let (issuer, bytes) = try await PermitLaneRunner(table: table).runFiles(.userVisible) { permit -> (BlockingPermit.Issuer, Data) in
            let bytes = try Data(blockingContentsOf: url, permit)
            return (permit.issuer, bytes)
        }
        await table.flush()

        #expect(issuer == .lane)
        #expect(bytes == Data("permit-read".utf8))
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @Test func thePermitFormWritesThroughTheSeam() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let url = try permitFixture("")
        try await PermitLaneRunner(table: table).runFiles(.bestEffort) { permit in
            try Data("permit-write".utf8).blockingWrite(to: url, permit, options: .atomic)
        }
        await table.flush()

        #expect(try Data(contentsOf: url) == Data("permit-write".utf8))
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @Test func aPostedRunnerBodyGetsALanePermit() async {
        let (issuers, report) = AsyncStream.makeStream(of: BlockingPermit.Issuer.self)
        PermitLaneRunner(table: BlockingViolationTable(mode: .record, poolMode: .record))
            .postFiles(.bestEffort, shutdown: .skipOnShutdown) { permit in report.yield(permit.issuer) }
        var iterator = issuers.makeAsyncIterator()
        #expect(await iterator.next() == .lane)
    }

    /// Every seam family has a permit form that runs the same checked call: in a lane body none of them records.
    @Test func theSeamFamiliesTakeThePermitAndRecordNothingInALane() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let url = try permitFixture("permit-seams")
        let (exists, text, statResult, image) = try await PermitLaneRunner(table: table).runFiles(.userVisible) {
            permit -> (Bool, String, Int32, Bool) in
            let exists = FileManager.checked.fileExists(atPath: url.path, permit)
            let text = try String(blockingContentsOf: url, encoding: .utf8, permit)
            var info = stat()
            let statResult = blockingStat(url.path, &info, permit)
            let image = CheckedImageSource(blockingContentsOf: url, permit) != nil
            return (exists, text, statResult, image)
        }
        await table.flush()

        #expect(exists)
        #expect(text == "permit-seams")
        #expect(statResult == 0)
        #expect(!image)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// A ``ChildProcessLauncher`` item gets a dedicated permit for the spawn seams.
    @Test func aLauncherItemGetsADedicatedPermit() async {
        let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.permit-tests", priority: .bestEffort)
        let ran = await launcher.run { (permit) throws(Never) -> BlockingPermit.Issuer in permit.issuer }
        let (posted, report) = AsyncStream.makeStream(of: BlockingPermit.Issuer.self)
        launcher.post { permit in report.yield(permit.issuer) }
        var iterator = posted.makeAsyncIterator()

        #expect(ran == .dedicated)
        #expect(await iterator.next() == .dedicated)
    }

    /// A reviewed allowance gives the permit off the main thread (a registered dedicated thread's path), and its
    /// seams are allowed there.
    @Test func anAllowanceGivesAPermitAndItsReadRecordsNothing() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let url = try permitFixture("permit-allowance")
        let issuer = await onPermitQueue(.global(qos: .utility)) { () -> BlockingPermit.Issuer in
            BlockingViolationTable.$scoped.withValue(table) {
                allowBlocking(BlockingAllowance(reviewed: "tests.permit")) { permit -> BlockingPermit.Issuer in
                    _ = try? Data(blockingContentsOf: url, permit)
                    return permit.issuer
                }
            }
        }
        await table.flush()

        #expect(issuer == .allowance)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The permit is for the compiler; the run-time detector stays the judge of where a call runs, so a permit
    /// that reached a pool thread does not hide the call.
    @Test func aPermitDoesNotSilenceThePoolCheck() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onPermitQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                blockingCall(.fileIO, BlockingPermit(issuer: .lane)) {}
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.context) == [.pool])
        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.fileIO])
    }
}

/// A ``MayBlockRunner`` that runs each body on a global queue marked as a lane, with `table` bound there (a dispatch
/// block does not inherit task-locals): BackgroundWork's lane in miniature, for a module below Wakeups.
nonisolated private final class PermitLaneRunner: MayBlockRunner {
    let table: BlockingViolationTable

    init(table: BlockingViolationTable) {
        self.table = table
    }

    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await onLane(body)
    }

    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await onLane(body)
    }

    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await onLane(body)
    }

    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void) {
        let table = table
        DispatchQueue.global(qos: priority.qos.qosClass).async {
            BlockingContext.runAsLane { BlockingViolationTable.$scoped.withValue(table) { body() } }
        }
    }

    private func onLane<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let table = table
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                done.resume(with: Result { () throws -> T in
                    try BlockingContext.runAsLane { () throws -> T in
                        try BlockingViolationTable.$scoped.withValue(table) { try body() }
                    }
                })
            }
        }
    }
}

private nonisolated func onPermitQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        queue.async { done.resume(returning: body()) }
    }
}

/// A new file in the temporary directory holding `contents`.
private nonisolated func permitFixture(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blocking-permit-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url)
    return url
}
#endif

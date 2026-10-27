#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
@testable import CmuxNextWakeups
import Foundation
import Testing

/// Every BackgroundWork lane entry point gives its body the lane's ``BlockingPermit``
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 111): `work.run(...) { permit in try Data(blockingContentsOf:
/// url, permit) }` compiles and its read records nothing, and the sequence, handle, host-resolution, reply and posted
/// forms give a `.lane` permit too.
@Suite(.timeLimit(.minutes(1))) struct BackgroundWorkPermitTests {
    @Test(arguments: [BlockingLane.files, .system])
    func thePermitFormOfAReadInWorkRunRecordsNothing(lane: BlockingLane) async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("work-permit-\(UUID().uuidString)")
        try Data("work-permit".utf8).write(to: url)
        let work = BackgroundWork(label: "test.work-permit")
        let (issuer, bytes) = try await work.run(.userVisible, mayBlock: lane) { permit -> (BlockingPermit.Issuer, Data) in
            let bytes = try BlockingViolationTable.$scoped.withValue(table) { try Data(blockingContentsOf: url, permit) }
            return (permit.issuer, bytes)
        }
        await table.flush()

        #expect(issuer == .lane)
        #expect(bytes == Data("work-permit".utf8))
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// A posted body gets the permit too; a zero-argument body still picks the old overload. The two items may run
    /// at once on two files slots, so their reports are compared as a set.
    @Test func aPostedBodyGetsTheLanePermit() async {
        let work = BackgroundWork(label: "test.work-permit")
        let (bodies, report) = AsyncStream.makeStream(of: String.self)
        work.post(.userVisible, mayBlock: .files) { permit in report.yield(permit.issuer == .lane ? "lane permit" : "other permit") }
        work.post(.userVisible, mayBlock: .files) { report.yield("no permit") }
        var iterator = bodies.makeAsyncIterator()
        let first = await iterator.next(), second = await iterator.next()
        #expect(Set([first, second]) == ["lane permit", "no permit"])
    }

    /// The permit form of `post` keeps `abandoned:`: an item shutdown refuses runs it instead of its body.
    @Test func aRefusedPermitPostRunsItsAbandonedHandler() async {
        let work = BackgroundWork(label: "test.work-permit")
        await work.shutdown()
        let (outcomes, report) = AsyncStream.makeStream(of: String.self)
        work.post(.userVisible, mayBlock: .files, abandoned: { report.yield("abandoned") }) { _ in report.yield("ran") }
        var iterator = outcomes.makeAsyncIterator()
        #expect(await iterator.next() == "abandoned")
    }

    @Test func aSequenceBodyGetsTheLanePermit() async throws {
        let saves = BackgroundWork(label: "test.work-permit").sequence("permit")
        let (posted, report) = AsyncStream.makeStream(of: BlockingPermit.Issuer.self)
        saves.post(.bestEffort) { permit in report.yield(permit.issuer) }
        let ran = try await saves.run(.userVisible) { permit -> BlockingPermit.Issuer in permit.issuer }
        var iterator = posted.makeAsyncIterator()

        #expect(await iterator.next() == .lane)
        #expect(ran == .lane)
    }

    @Test func aHandleBodyGetsTheLanePermit() async throws {
        let handle = BackgroundWork(label: "test.work-permit").runHandle(.userVisible, mayBlock: .files) { permit -> BlockingPermit.Issuer in
            permit.issuer
        }
        #expect(try await handle.value == .lane)
    }

    @Test func aHostResolutionBodyGetsTheLanePermit() async throws {
        let issuer = try await BackgroundWork(label: "test.work-permit").resolveHost(.userVisible) { permit -> BlockingPermit.Issuer in
            permit.issuer
        }
        #expect(issuer == .lane)
    }

    /// The reply form wraps the body once: the work it queues hands the body a `.lane` permit.
    @Test func aReplyFormBodyGetsTheLanePermit() {
        let pending: BackgroundWork.Pending<BlockingPermit.Issuer> = BackgroundWork(label: "test.work-permit")
            .run(.userVisible, mayBlock: .files) { permit in permit.issuer }
        #expect(pending.body() == .lane)
    }
}
#endif

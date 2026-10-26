#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A BackgroundWork lane body gets the lane's ``BlockingPermit`` (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 111): `work.run(...) { permit in try Data(blockingContentsOf: url, permit) }` compiles and its read
/// records nothing.
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

    /// A posted body gets the permit too; a zero-argument body still picks the old overload.
    @Test func aPostedBodyGetsTheLanePermit() async {
        let work = BackgroundWork(label: "test.work-permit")
        let (bodies, report) = AsyncStream.makeStream(of: String.self)
        work.post(.userVisible, mayBlock: .files) { permit in report.yield(permit.issuer == .lane ? "lane permit" : "other permit") }
        work.post(.userVisible, mayBlock: .files) { report.yield("no permit") }
        var iterator = bodies.makeAsyncIterator()
        #expect(await iterator.next() == "lane permit")
        #expect(await iterator.next() == "no permit")
    }
}
#endif

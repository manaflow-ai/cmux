#if DEBUG
@testable import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `debug.blocking` reports a detector's sites off the main thread and zeroes counts on request.
@Suite
struct BlockingControlTests {
    @MainActor @Test func reportsSitesAndResetsCounts() async throws {
        let table = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(table) {
            for _ in 0..<2 { _ = FileManager.checked.fileExists(atPath: "/") }
        }
        await table.flush()
        let detector = BlockingDetector(table: table)

        let first = BlockingControl.report(["reset": .bool(true)], detector: detector)
        let sites = try #require(first.objectValue?["sites"]?.arrayValue)
        #expect(first.objectValue?["mode"]?.stringValue == "record")
        #expect(sites.count == 1)
        #expect(sites.first?.objectValue?["kind"]?.stringValue == "file-io")
        #expect(sites.first?.objectValue?["count"]?.intValue == 2)
        #expect(detector.sites.map(\.count) == [0])
    }

    /// The report shows the table's mode, and the method reads only `reset`: a `mode` parameter changes
    /// nothing (trap mode comes only from `CMUX_BLOCKING_TRAP=1` at launch).
    @Test func theReportShowsTheModeAndReadsOnlyReset() async {
        let trap = BlockingDetector(table: BlockingViolationTable(mode: .trap))
        let record = BlockingDetector(table: BlockingViolationTable(mode: .record))
        #expect(BlockingControl.report([:], detector: trap).objectValue?["mode"]?.stringValue == "trap")
        #expect(BlockingControl.report([:], detector: record).objectValue?["mode"]?.stringValue == "record")
        #expect(BlockingControl.report(["mode": .string("trap")], detector: record)
                == BlockingControl.report([:], detector: record))
        #expect(BlockingControl.report(["reset": .bool(false)], detector: record).objectValue?["overflow"]?.intValue == 0)
    }
}
#endif

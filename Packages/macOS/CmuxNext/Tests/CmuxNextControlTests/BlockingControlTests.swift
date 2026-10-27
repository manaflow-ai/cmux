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
        #expect(first.objectValue?["compiled_in"]?.boolValue == true)
        #expect(sites.count == 1)
        #expect(sites.first?.objectValue?["kind"]?.stringValue == "file-io")
        #expect(sites.first?.objectValue?["seam_kind"]?.stringValue == "file-io")
        #expect(sites.first?.objectValue?["count"]?.intValue == 2)
        #expect(detector.sites.map(\.count) == [0])
    }

    /// A 5 ms sleep in `blockingCall` on the main thread shows as `max_ms` >= 5 (and `total_ms` >= `max_ms`).
    @MainActor @Test func reportsTheWallTimeOfATimedSite() async throws {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            blockingCall(.sleep) { _ = usleep(5_000) }
        }
        await table.flush()

        let report = BlockingControl.report([:], detector: BlockingDetector(table: table))
        let site = try #require(report.objectValue?["sites"]?.arrayValue?.first?.objectValue)
        let maxMs = try #require(site["max_ms"]?.doubleValue)
        let totalMs = try #require(site["total_ms"]?.doubleValue)
        #expect(maxMs >= 5)
        #expect(totalMs >= maxMs)
    }

    /// A seam on the pool (a detached task) is a `pool` site, one in a `.cpu` lane item a `cpu-lane` site
    /// of kind `wrong-lane` with the seam's own `seam_kind`, and a semaphore wait in a lane item a `lane-sync`
    /// site; `contexts` splits the sites and calls by context.
    @MainActor @Test func reportsSitesByContext() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        BlockingViolationTable.$scoped.withValue(table) { _ = FileManager.checked.fileExists(atPath: "/") }
        await Task.detached {
            BlockingViolationTable.$scoped.withValue(table) {
                for _ in 0..<2 { _ = FileManager.checked.fileExists(atPath: "/") }
                BlockingContext.runAsCPULane { _ = FileManager.checked.fileExists(atPath: "/") }
                BlockingContext.runAsLane {
                    // Made at 0 and signaled once: a semaphore made at 1 traps when released below that value.
                    let semaphore = DispatchSemaphore(value: 0)
                    semaphore.signal()
                    semaphore.blockingWait()
                }
            }
        }.value
        await table.flush()

        let report = BlockingControl.report([:], detector: BlockingDetector(table: table))
        let sites = try #require(report.objectValue?["sites"]?.arrayValue)
        #expect(Set(sites.compactMap { $0.objectValue?["context"]?.stringValue })
            == ["main", "pool", "cpu-lane", "lane-sync"])
        let cpuLane = try #require(sites.first { $0.objectValue?["context"]?.stringValue == "cpu-lane" }?.objectValue)
        #expect(cpuLane["kind"]?.stringValue == "wrong-lane")
        #expect(cpuLane["seam_kind"]?.stringValue == "file-io")
        let contexts = try #require(report.objectValue?["contexts"]?.objectValue)
        #expect(contexts["main"]?.objectValue?["sites"]?.intValue == 1)
        #expect(contexts["main"]?.objectValue?["count"]?.intValue == 1)
        #expect(contexts["pool"]?.objectValue?["sites"]?.intValue == 1)
        #expect(contexts["pool"]?.objectValue?["count"]?.intValue == 2)
        #expect(contexts["main"]?.objectValue?["overflow"]?.intValue == 0)
        #expect(contexts["pool"]?.objectValue?["overflow"]?.intValue == 0)
        #expect(contexts["cpu-lane"]?.objectValue?["sites"]?.intValue == 1)
        #expect(contexts["cpu-lane"]?.objectValue?["count"]?.intValue == 1)
        #expect(contexts["cpu-lane"]?.objectValue?["overflow"]?.intValue == 0)
        #expect(contexts["lane-sync"]?.objectValue?["sites"]?.intValue == 1)
        #expect(contexts["lane-sync"]?.objectValue?["count"]?.intValue == 1)
        #expect(report.objectValue?["pool_mode"]?.stringValue == "record")
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

    /// A user-interactive `blockingSync` onto a utility queue is one site under `inversions`, with both classes;
    /// `reset` zeroes its count.
    @Test func reportsQoSInversions() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let utility = DispatchQueue(label: "com.cmuxterm.tests.control-qos-utility", qos: .utility)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "com.cmuxterm.tests.control-qos-waiter", qos: .userInteractive).async {
                BlockingViolationTable.$scoped.withValue(table) { utility.blockingSync {} }
                done.resume()
            }
        }
        await table.flush()
        let detector = BlockingDetector(table: table)

        let report = BlockingControl.report(["reset": .bool(true)], detector: detector)
        let inversions = try #require(report.objectValue?["inversions"]?.objectValue)
        #expect(inversions["count"]?.intValue == 1)
        #expect(inversions["overflow"]?.intValue == 0)
        let site = try #require(inversions["sites"]?.arrayValue?.first?.objectValue)
        #expect(site["waiter"]?.stringValue == "user-interactive")
        #expect(site["target"]?.stringValue == "utility")
        #expect(site["count"]?.intValue == 1)
        let after = BlockingControl.report([:], detector: detector)
        #expect(after.objectValue?["inversions"]?.objectValue?["count"]?.intValue == 0)
    }
}
#endif

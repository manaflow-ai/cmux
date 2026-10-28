#if DEBUG
@testable import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// `debug.pool_context` (chrome-parity p02-threads RUN-10, task 305): each case's thread gets its context, the pool
/// and `.cpu` cases' seam calls are recorded at their own sites and the `.files` one is not, and a raise of a running
/// best-effort item lifts its thread's priority with its requested QoS unchanged. The Tart matrix runs the same
/// method on macOS 14 and 15 (scripts/fuzz/macos-matrix/threads.py).
@Suite(.serialized)
struct PoolContextControlTests {
    private func control(_ table: BlockingViolationTable, label: String) -> PoolContextControl {
        PoolContextControl(work: BackgroundWork(cpuWidth: 1, label: label), detector: BlockingDetector(table: table)) { fileID, line in
            // A detached task or a dispatch block does not inherit task-locals: bind the table on the calling thread.
            BlockingViolationTable.$scoped.withValue(table) {
                _ = FileManager.checked.fileExists(atPath: "/", fileID: fileID, line: line)
            }
        }
    }

    @Test func eachCaseGetsItsContextAndOnlyThePoolAndCPUCasesRecord() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let cases = try await control(table, label: "test.pool-context.cases").runCases()
        #expect(cases.map(\.name) == ["task_detached", "global_queue", "lane_files", "lane_cpu"])
        for item in cases {
            #expect(item.observed.context == item.expected, "\(item.name) ran on \(item.observed.label)")
        }
        #expect(cases.filter { $0.expected == .pool }.allSatisfy { $0.observed.label.hasPrefix("com.apple.root.") })
        #expect(Set(cases.map(\.observed.site)).count == cases.count)

        await table.flush()
        let recorded = Dictionary(table.sites.map { ($0.location, $0.context) }, uniquingKeysWith: { first, _ in first })
        #expect(recorded[cases[0].observed.site] == .pool)
        #expect(recorded[cases[1].observed.site] == .pool)
        #expect(recorded[cases[2].observed.site] == nil)
        #expect(recorded[cases[3].observed.site] == .cpuLane)
    }

    @Test func aRaiseLiftsTheRunningItemsPriorityAndKeepsItsRequestedQoS() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let (before, after) = try await control(table, label: "test.pool-context.raise").raiseRunningItem()
        #expect(before.qos == .utility)
        #expect(after.qos == .utility)
        let base = try #require(before.priority)
        let lifted = try #require(after.priority)
        #expect(lifted > base)
    }

    @Test func theReportNamesEachCaseAndTheRaise() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let report = try await control(table, label: "test.pool-context.report").report()
        let object = try #require(report.objectValue)
        #expect(object["compiled_in"]?.boolValue == true)
        let cases = try #require(object["cases"]?.arrayValue).compactMap(\.objectValue)
        #expect(cases.map { $0["context"]?.stringValue } == ["pool", "pool", "lane", "cpu-lane"])
        #expect(cases.map { $0["expected"]?.stringValue } == ["pool", "pool", "lane", "cpu-lane"])
        let raise = try #require(object["raise"]?.objectValue)
        #expect(raise["before"]?.objectValue?["qos"]?.stringValue == "utility")
        #expect(raise["after"]?.objectValue?["priority"]?.doubleValue != nil)
    }

    @Test func aTrappingPoolIsRefused() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .trap)
        let report = try await control(table, label: "test.pool-context.trap").report()
        #expect(report.objectValue?["refused"]?.stringValue != nil)
        #expect(report.objectValue?["cases"] == nil)
    }
}
#endif

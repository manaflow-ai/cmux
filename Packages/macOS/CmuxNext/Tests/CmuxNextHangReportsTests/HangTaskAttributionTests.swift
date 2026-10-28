@testable import CmuxNextHangReports
import Foundation
import Testing

/// A watchdog hang in an opt-in hang report names the scheduled task it caught: its
/// owner and class, or `unattributed`, in wire schema 3 only (the deployed schema-2 server refuses the key),
/// through the builder's allow-list.
struct HangTaskAttributionTests {
    private static func collector() -> HangReportCollector {
        HangReportCollector(resolve: { _ in [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)] },
                            schedule: { $0() })
    }

    private static func builder(_ schema: HangReport.WireSchema) -> HangReportBuilder {
        HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.FakeResolver(), wireSchema: schema)
    }

    private static func aggregate(_ tasks: [HangSample.MainTask]) -> StallAggregate {
        let collector = collector()
        collector.setEnabled(true)
        for (index, task) in tasks.enumerated() {
            collector.noteHang(durationNanos: UInt64(2_000 + index) * 1_000_000, addresses: [1], task: task)
        }
        return collector.drain()
    }

    @Test func aSchema3HangCarriesItsOwnerAndClass() throws {
        let aggregate = Self.aggregate([
            .init(owner: "SidebarRows", taskClass: "visible"),
            .init(owner: HangSample.MainTask.unattributed, taskClass: HangSample.MainTask.unattributed),
        ])
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])

        #expect(report.hangs.map(\.mainTask) == [
            .init(owner: "unattributed", taskClass: "unattributed"),
            .init(owner: "SidebarRows", taskClass: "visible"),
        ])
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""task":{"class":"visible","owner":"SidebarRows"}"#), "\(text)")
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded.hangs.map(\.mainTask) == report.hangs.map(\.mainTask))
    }

    @Test func aSchema2HangCarriesNoTaskKey() throws {
        let aggregate = Self.aggregate([.init(owner: "SidebarRows", taskClass: "visible")])
        let report = Self.builder(.v2).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])

        #expect(report.hangs.count == 1)
        #expect(report.hangs.allSatisfy { $0.mainTask == nil })
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("\"task\""), "a schema-2 server answers 400 to an unknown key: \(text)")
    }

    /// The owner is a code-defined identifier: a configured command's name, a path or free text is `other`;
    /// a class outside ``MainWorkClass``'s names is `unattributed`.
    @Test func theBuilderSendsOnlyAllowListedOwnersAndClasses() {
        let aggregate = Self.aggregate([
            .init(owner: "cmuxConfig.deploy-acme", taskClass: "input"),
            .init(owner: "/Users/someone/secret", taskClass: "visible"),
            .init(owner: "tab focus", taskClass: "automation"),
            .init(owner: String(repeating: "a", count: 65), taskClass: "frame"),
            .init(owner: "control.snapshot.publish", taskClass: "made-up"),
        ])
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])

        #expect(report.hangs.map(\.mainTask) == [
            .init(owner: "control.snapshot.publish", taskClass: "unattributed"),
            .init(owner: "other", taskClass: "frame"),
            .init(owner: "other", taskClass: "automation"),
            .init(owner: "other", taskClass: "visible"),
            .init(owner: "other", taskClass: "input"),
        ])
    }
}

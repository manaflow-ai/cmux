@testable import CmuxNextHangReports
import Foundation
import Testing

/// A watchdog stall or hang before startup completion names the launch phase and the `main()` step or startup
/// task it ran in, in wire schema 3 only (the deployed schema-2 server refuses the key),
/// through the builder's allow-list.
struct HangStartupTagTests {
    private static func builder(_ schema: HangReport.WireSchema) -> HangReportBuilder {
        HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.FakeResolver(), wireSchema: schema)
    }

    /// One launch stall (300 ms, in `main.launch_reads`) and one launch hang (2.5 s, in the critical task
    /// `ThemeBridge.start`), as the app's watchdog sinks note them.
    private static func aggregate(stall: HangSample.Startup? = HangSample.Startup(phase: "main", task: "main.launch_reads"),
                                  hang: HangSample.Startup? = HangSample.Startup(phase: "critical", task: "ThemeBridge.start")) -> StallAggregate {
        let collector = HangReportCollector(
            resolve: { _ in [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)] }, schedule: { $0() })
        collector.setEnabled(true)
        collector.noteStall(durationNanos: 300_000_000, cpuNanos: 290_000_000, addresses: [1], startup: stall)
        collector.noteHang(durationNanos: 2_500_000_000, addresses: [1], task: .init(owner: "unattributed", taskClass: "unattributed"),
                           startup: hang)
        return collector.drain()
    }

    @Test func aSchema3StallAndHangCarryTheirLaunchPhaseAndTask() throws {
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(), metricKit: [])

        #expect(report.hangs.map(\.startup) == [
            HangSample.Startup(phase: "critical", task: "ThemeBridge.start"),
            HangSample.Startup(phase: "main", task: "main.launch_reads"),
        ])
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""startup":{"phase":"main","task":"main.launch_reads"}"#), "\(text)")
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded.hangs.map(\.startup) == report.hangs.map(\.startup))
    }

    @Test func aSchema2ReportCarriesNoStartupKey() throws {
        let report = Self.builder(.v2).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(), metricKit: [])

        #expect(report.hangs.count == 2)
        #expect(report.hangs.allSatisfy { $0.startup == nil })
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("\"startup\""), "a schema-2 server answers 400 to an unknown key: \(text)")
    }

    /// A stall after startup completed has no tag; an unknown phase drops the field; a task name that is not a
    /// code identifier is `other`; a stall between tasks names only its phase.
    @Test func theBuilderSendsOnlyAKnownPhaseAndACodeDefinedTask() {
        let sanitized = { (startup: HangSample.Startup?) in
            Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(stall: startup, hang: nil),
                                    metricKit: []).hangs.first { $0.kind == .stall }?.startup
        }
        #expect(HangSample.Startup(stallPhase: nil, task: "late.step") == nil, "a stall after startup names no phase")
        #expect(HangSample.Startup(stallPhase: "main", task: nil) == HangSample.Startup(phase: "main", task: nil))
        #expect(sanitized(nil) == nil)
        #expect(sanitized(.init(phase: "made_up", task: "main.warmup")) == nil)
        #expect(sanitized(.init(phase: "main", task: "/Users/someone/secret")) == .init(phase: "main", task: "other"))
        #expect(sanitized(.init(phase: "critical", task: nil)) == .init(phase: "critical", task: nil))
        #expect(sanitized(.init(phase: "after_first_frame", task: "SidebarRows.prime")) == .init(phase: "after_first_frame", task: "SidebarRows.prime"))
    }
}

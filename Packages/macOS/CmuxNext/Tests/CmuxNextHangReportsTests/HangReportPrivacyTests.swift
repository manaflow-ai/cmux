@testable import CmuxNextHangReports
import Foundation
import Testing

/// A report built from realistic MetricKit payloads and watchdog stacks with planted private
/// data holds none of it, keeps our and Apple's frames symbolicatable, and passes the leak scan.
/// The rules are Rust's (cmux-hang-report's tests); these run them end to end through the FFI.
struct HangReportPrivacyTests {
    private func composed(_ context: HangReportBuilder.Context = HangReportFixtures.context(), samples: Bool = true)
        -> HangReportBuilder.Composed? {
        let builder = HangReportFixtures.builder()
        var aggregate = StallAggregate()
        if samples {
            aggregate.count(bucket: 2)
            aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 300, cpuMs: 290,
                                      frames: builder.frames(addresses: HangReportFixtures.watchdogAddresses)))
        }
        return builder.compose(context: context, watchdog: aggregate, metricKit: samples ? [HangReportFixtures.metricKitInput()] : [])
    }

    private func report() -> (HangReport, Data) {
        let body = composed()?.body ?? Data()
        let report = (try? JSONDecoder().decode(HangReport.self, from: body))
            ?? HangReport(reportId: "", installId: "", day: "", app: HangReport.App(version: "", build: "", channel: ""),
                          os: HangReport.OS(version: ""), hardware: HardwareClass(arch: "", chip: "", cores: 0, memoryGB: 0),
                          counts: .unknown)
        return (report, body)
    }

    @Test func aBuiltReportIsReadyToQueue() {
        #expect(composed()?.status == .ok)
    }

    @Test func noPlantedStringReachesTheEncodedReport() throws {
        let (_, body) = report()
        let text = try #require(String(data: body, encoding: .utf8)).lowercased()
        for secret in HangReportFixtures.planted {
            #expect(!text.contains(secret.lowercased()), "leaked: \(secret)")
        }
        let readable = try String(decoding: #require(composed()?.readable), as: UTF8.self).lowercased()
        for secret in HangReportFixtures.planted {
            #expect(!readable.contains(secret.lowercased()), "leaked in the readable copy: \(secret)")
        }
    }

    @Test func theLeakScannerFindsNothingInABuiltReport() {
        let (_, body) = report()
        let findings = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func thirdPartyFramesLoseNameUUIDAndOffset() {
        let (report, _) = report()
        let frames = report.hangs.flatMap(\.frames) + report.cpuExceptions.flatMap(\.frames)
        #expect(frames.contains(.other))
        for frame in frames where frame.isOther {
            #expect(frame.uuid == nil && frame.offset == nil)
        }
        let named = Set(frames.filter { !$0.isOther }.map(\.image))
        #expect(named == ["AppKit", "cmux NEXT Nightly", "GhosttyKit", "libsystem_kernel.dylib"], "\(named)")
        #expect(!frames.contains { [HangReportFixtures.imeUUID, HangReportFixtures.pluginUUID].contains($0.uuid ?? "") })
    }

    @Test func ourAndApplesFramesKeepUUIDAndOffset() throws {
        let (report, _) = report()
        let metricKit = try #require(report.hangs.first { $0.source == .metrickit })
        // Innermost first: the input method (other), AppKit, our binary, GhosttyKit.
        #expect(metricKit.frames == [
            .other,
            HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 123_456),
            HangReportFrame(image: "cmux NEXT Nightly", uuid: HangReportFixtures.appUUID, offset: 777),
            HangReportFrame(image: "GhosttyKit", uuid: HangReportFixtures.ghosttyUUID, offset: 55),
        ])
        let watchdog = try #require(report.hangs.first { $0.source == .watchdog })
        #expect(watchdog.frames == [
            .other,
            HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 0x2000),
            HangReportFrame(image: "cmux NEXT Nightly", uuid: HangReportFixtures.appUUID, offset: 0x300),
            .other, .other,
        ])
    }

    @Test func onlyAllowlistedIntervalsAreSent() {
        let (report, _) = report()
        #expect(report.intervals.map(\.category) == ["motion"])
        #expect(report.intervals.first?.name == "motion.frame")
        #expect(report.intervals.first?.count == 1_200)
    }

    @Test func unsafeEnvelopeValuesAreReplaced() throws {
        var context = HangReportFixtures.context()
        context.app = HangReport.App(version: "0.70.0 (alice@example.com)", build: "/Users/alice", channel: "WorkspaceSecretProject")
        context.os = HangReport.OS(version: "Version 15.7.4 (Build 24G517) alice")
        context.day = "2026-10-23T10:11:12Z"
        let body = try #require(composed(context)?.body)
        let report = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(report.app == HangReport.App(version: "0", build: "0", channel: "dev"))
        #expect(report.os.version == "0")
        #expect(report.day == "1970-01-01")
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
    }

    @Test func aNightlyRunIDBuildNumberIsKept() throws {
        var context = HangReportFixtures.context()
        context.app = HangReport.App(version: "0.70.0", build: "2123456789012", channel: "nightly")
        let body = try #require(composed(context)?.body)
        let report = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(report.app.build == "2123456789012")
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
    }

    @Test func hardwareClassKeepsOnlyCoarseValues() {
        #expect(HardwareClass(rawArch: "arm64e", rawChip: "Apple M4 Pro", cores: 14, memoryBytes: 48 << 30)
            == HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48))
        #expect(HardwareClass(rawArch: "arm64", rawChip: "Alice's Hackintosh 3000", cores: 8, memoryBytes: 17 << 30).chip == "other")
        #expect(HardwareClass(rawArch: "x86_64", rawChip: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", cores: 16,
                              memoryBytes: 31 << 30) == HardwareClass(arch: "x86_64", chip: "Intel", cores: 16, memoryGB: 32))
    }
}

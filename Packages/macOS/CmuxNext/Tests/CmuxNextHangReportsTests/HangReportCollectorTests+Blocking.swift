#if DEBUG || CMUX_BLOCKING_CHECKS
import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// p09-observability-089: the blocking detector's drain hands each new site (kind, context, image UUID + offset
/// frames) to the collector, and a schema 3 report carries the sites in their own `blocking[]`, at most 32, with
/// nothing that names a path. Compiled only where the detector is (Debug and `CMUX_BLOCKING_CHECKS`).
extension HangReportCollectorTests {
    private static let blockingBuilder = HangReportFixtures.builder(wireSchema: .v3)

    private static func blockingCollector() -> HangReportCollector {
        HangReportCollector(resolve: { blockingBuilder.frames(addresses: $0) },
                            resolveBlocking: { blockingBuilder.frames(blocking: $0) }, schedule: { $0() })
    }

    private static func frame(_ uuid: String, _ offset: UInt64) -> BlockingFrame {
        BlockingFrame(imageUUID: UUID(uuidString: uuid) ?? UUID(), offset: offset)
    }

    /// Sites in our binary, in an input method under the person's home folder (`/Users/alice/Library/Input
    /// Methods/SecretIME.app`), in a third-party plugin (`EvilPlugin.app`) and in an image this process does not
    /// have, then more sites than the list holds: the body names none of the planted paths or names.
    @Test func blockingSitesGoToSchema3BlockingListWithNoPlantedPath() throws {
        let collector = Self.blockingCollector()
        collector.setEnabled(true)
        let planted = [HangReportFixtures.appUUID, HangReportFixtures.imeUUID, HangReportFixtures.pluginUUID,
                       UUID().uuidString]
        for (index, image) in planted.enumerated() {
            collector.noteBlocking(BlockingViolation(kind: .fileIO, context: index.isMultiple(of: 2) ? .main : .pool, frames: [
                Self.frame(image, 0x100 + UInt64(index)), Self.frame(HangReportFixtures.appKitUUID, 0x2000),
            ]))
        }
        for offset in 0..<UInt64(HangReport.maxBlocking) {
            collector.noteBlocking(BlockingViolation(kind: .syncWait, frames: [Self.frame(HangReportFixtures.appUUID, 0x9000 + offset)]))
        }
        collector.noteStall(durationNanos: 400_000_000, cpuNanos: 0, addresses: [0x1_0000_0300])

        let report = HangReportService.fitted(
            Self.blockingBuilder.build(context: HangReportFixtures.context(), watchdog: collector.drain(), metricKit: []))
        let body = try HangReport.encoder.encode(report)

        let sites = try #require(report.blocking)
        #expect(sites.count == HangReport.maxBlocking)
        #expect(sites.allSatisfy { $0.source == .detector && $0.kind == .blocking && $0.durationMs == 0 })
        #expect(sites.prefix(planted.count).map { $0.frames.first } == [
            HangReportFrame(image: "cmux NEXT Nightly", uuid: HangReportFixtures.appUUID, offset: 0x100),
            HangReportFrame.other, HangReportFrame.other, HangReportFrame.other,
        ])
        #expect(sites[1].blocking == HangSample.Blocking(kind: .fileIO, context: .pool))
        #expect(report.hangs.map(\.kind) == [.stall])
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        for secret in HangReportFixtures.planted {
            #expect(!text.lowercased().contains(secret.lowercased()), "leaked: \(secret)")
        }
    }

    /// Off (the person said no), a site the drain hands over is not kept.
    @Test func blockingSitesAreNotKeptWhileReportsAreOff() {
        let collector = Self.blockingCollector()
        collector.setEnabled(false)
        collector.noteBlocking(BlockingViolation(kind: .fileIO, frames: [Self.frame(HangReportFixtures.appUUID, 0x10)]))

        #expect(collector.drain().isEmpty)
    }
}
#endif

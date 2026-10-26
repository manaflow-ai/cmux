@testable import CmuxNextHangReports
import Foundation
import Testing

/// A registered thread's hang becomes one hang-report entry that names the thread, only with a
/// catalog-shaped name, and never in a schema 2 report (task p09-observability-068).
struct ThreadHangReportTests {
    private static let frame = HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)

    private func collector(keepsThreadHangs: Bool) -> HangReportCollector {
        HangReportCollector(resolve: { _ in [Self.frame] }, keepsThreadHangs: keepsThreadHangs, schedule: { $0() })
    }

    @Test func aThreadHangIsAnEntryThatNamesTheThread() {
        let collector = collector(keepsThreadHangs: true)
        collector.setEnabled(true)
        collector.noteThreadHang(thread: "terminal-output", overdueNanos: 1_500_000_000, addresses: [1, 2, 3])
        let hangs = collector.snapshot().hangs
        #expect(hangs.count == 1)
        #expect(hangs.first?.thread == "terminal-output")
        #expect(hangs.first?.kind == .hang)
        #expect(hangs.first?.source == .watchdog)
        #expect(hangs.first?.durationMs == 1_500)
        #expect(hangs.first?.frames == [Self.frame])
    }

    @Test func offOrWithoutAStackRecordsNothing() {
        let collector = collector(keepsThreadHangs: true)
        collector.noteThreadHang(thread: "daemon-reader", overdueNanos: 2_000_000_000, addresses: [1])
        collector.setEnabled(true)
        collector.noteThreadHang(thread: "daemon-reader", overdueNanos: 2_000_000_000, addresses: [])
        #expect(collector.drain().isEmpty)
    }

    /// The schema 2 server refuses an unknown key, so the default collector drops thread hangs until the
    /// report schema carries `thread`.
    @Test func theDefaultFollowsTheReportSchema() {
        let collector = HangReportCollector(resolve: { _ in [Self.frame] }, schedule: { $0() })
        collector.setEnabled(true)
        collector.noteThreadHang(thread: "control", overdueNanos: 2_000_000_000, addresses: [1])
        #expect(collector.snapshot().hangs.isEmpty == (HangReport.schemaVersion < HangSample.threadSchemaVersion))
    }

    @Test func aMainThreadEntryEncodesNoThreadKey() throws {
        let main = HangSample(source: .watchdog, kind: .hang, durationMs: 2_000, frames: [.other])
        let body = try String(decoding: JSONEncoder().encode(main), as: UTF8.self)
        #expect(!body.contains("thread"))
        let named = HangSample(source: .watchdog, kind: .hang, durationMs: 2_000, frames: [.other], thread: "control")
        let decoded = try JSONDecoder().decode(HangSample.self, from: JSONEncoder().encode(named))
        #expect(decoded.thread == "control")
    }

    @Test func aNameOutsideTheCatalogShapeIsOther() {
        #expect(HangSample(source: .watchdog, kind: .hang, durationMs: 1, frames: [], thread: "mux-control.dispatch_2").thread
            == "mux-control.dispatch_2")
        for name in ["", "Terminal Output", "/Users/someone/x", "née", String(repeating: "a", count: HangSample.maxThreadNameBytes + 1)] {
            #expect(HangSample(source: .watchdog, kind: .hang, durationMs: 1, frames: [], thread: name).thread == "other", "\(name)")
        }
    }
}

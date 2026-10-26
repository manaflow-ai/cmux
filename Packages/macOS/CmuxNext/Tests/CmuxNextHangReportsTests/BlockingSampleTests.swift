import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// The blocking detector's call sites in opt-in hang reports (p02-threads-008): one sample per site
/// with its kind, context and UUID + offset frames, nothing that names a path, the sites a launch
/// records before the setting is read kept, and the crash-report budget of 5 per launch and 1 per
/// site per 24 h.
struct BlockingSampleTests {
    private static let builder = HangReportFixtures.builder()

    private static func collector() -> HangReportCollector {
        HangReportCollector(resolve: { builder.frames(addresses: $0) }, resolveBlocking: { builder.frames(blocking: $0) },
                            schedule: { $0() })
    }

    private static func uuid(_ text: String) -> UUID { UUID(uuidString: text) ?? UUID() }

    /// A file read from our binary through AppKit, with an input method's frame in the middle.
    private static let fileRead = BlockingViolation(kind: .fileIO, frames: [
        BlockingFrame(imageUUID: uuid(HangReportFixtures.appUUID), offset: 0x300),
        BlockingFrame(imageUUID: uuid(HangReportFixtures.imeUUID), offset: 0x40),
        BlockingFrame(imageUUID: uuid(HangReportFixtures.appKitUUID), offset: 0x2000),
        BlockingFrame(imageUUID: UUID(), offset: 0x10),  // an image this process does not have
    ])

    private static let semaphoreWait = BlockingViolation(kind: .syncWait, frames: [
        BlockingFrame(imageUUID: uuid(HangReportFixtures.appUUID), offset: 0x900),
    ])

    // MARK: the sample

    @Test func aSiteBecomesOneSampleWithItsKindContextAndFrames() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteBlocking(Self.fileRead, context: .main)

        let blocking = collector.snapshot().blocking
        #expect(blocking.count == 1)
        let sample = try #require(blocking.first)
        #expect(sample.source == .detector)
        #expect(sample.kind == .blocking)
        #expect(sample.blocking == HangSample.Blocking(kind: .fileIO, context: .main))
        #expect(sample.frames == [
            HangReportFrame(image: "cmux NEXT Nightly", uuid: HangReportFixtures.appUUID, offset: 0x300),
            .other,
            HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 0x2000),
            .other,
        ])
    }

    @Test func theReportCarriesTheSampleAndNothingThatNamesAPath() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteBlocking(Self.fileRead, context: .main)
        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: collector.drain(), metricKit: [])
        let body = try HangReport.encoder.encode(report)

        #expect(report.hangs.filter { $0.kind == .blocking }.count == 1)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8)).lowercased()
        for secret in HangReportFixtures.planted {
            #expect(!text.contains(secret.lowercased()), "leaked: \(secret)")
        }
        #expect(text.contains("\"file-io\""))
    }

    /// Blocking samples have no duration: a report full of long stalls still carries them.
    @Test func longStallsDoNotPushTheBlockingSamplesOut() {
        var aggregate = StallAggregate()
        for index in 0..<StallAggregate.maxSamples {
            aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 300 + index, frames: []))
            aggregate.keep(HangSample(source: .watchdog, kind: .hang, durationMs: 3_000 + index, frames: []))
        }
        for offset in 0..<UInt64(StallAggregate.maxSamples) {
            aggregate.keep(.blockingSite(HangSample.Blocking(kind: .fileIO, context: .main),
                                         frames: [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: offset)]))
        }
        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])

        #expect(report.hangs.count == HangReport.maxHangs)
        #expect(report.hangs.filter { $0.kind == .blocking }.count == StallAggregate.maxSamples)
        // The others are cut longest first: the 4 shortest stalls are out.
        #expect(report.hangs.filter { $0.kind == .stall }.map(\.durationMs) == [307, 306, 305, 304])
    }

    @Test func aSiteSeenAgainAddsNothing() {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteBlocking(Self.fileRead, context: .main)
        collector.noteBlocking(Self.fileRead, context: .main)
        collector.noteBlocking(Self.semaphoreWait, context: .main)

        #expect(collector.snapshot().blocking.map(\.blocking?.kind) == ["file-io", "sync-wait"])
    }

    @Test func atMostMaxSamplesSitesAreKept() {
        let collector = Self.collector()
        collector.setEnabled(true)
        for offset in 0..<UInt64(StallAggregate.maxSamples + 3) {
            collector.noteBlocking(BlockingViolation(kind: .fileIO, frames: [
                BlockingFrame(imageUUID: Self.uuid(HangReportFixtures.appUUID), offset: offset),
            ]), context: .main)
        }

        #expect(collector.snapshot().blocking.count == StallAggregate.maxSamples)
    }

    // MARK: before the setting is read (the detector's install replay)

    @Test func aSiteBeforeTheSettingIsReadIsKeptUntilReportsTurnOn() {
        let collector = Self.collector()
        collector.noteBlocking(Self.fileRead, context: .main)  // replayed at install, before setEnabled
        collector.setEnabled(true)

        #expect(collector.snapshot().blocking.count == 1)
    }

    @Test func aSiteBeforeTheSettingIsReadIsDroppedWhenReportsAreOff() {
        let collector = Self.collector()
        collector.noteBlocking(Self.fileRead, context: .main)
        collector.setEnabled(false)
        collector.noteBlocking(Self.semaphoreWait, context: .main)

        #expect(collector.snapshot().isEmpty)
    }

    // MARK: saved aggregates

    @Test func anAggregateSavedBeforeBlockingSamplesStillLoads() throws {
        let old = Data(#"{"counts":[1,0,0,0,0,0,0,0],"stalls":[],"hangs":[]}"#.utf8)
        let aggregate = try JSONDecoder().decode(StallAggregate.self, from: old)

        #expect(aggregate.blocking.isEmpty)
        #expect(aggregate.counts.first == 1)
    }

    @Test func blockingSamplesSurviveTheSaveAndMergeOnce() throws {
        var aggregate = StallAggregate()
        aggregate.keep(.blockingSite(HangSample.Blocking(kind: .fileIO, context: .main), frames: [.other]))
        let saved = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(aggregate))
        aggregate.merge(saved)

        #expect(saved == aggregate)
        #expect(aggregate.blocking.count == 1)
    }

    // MARK: the crash-report budget

    @Test func fiveSitesPerLaunch() {
        var budget = BlockingReportBudget()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let admitted = (0..<7).filter { budget.admit(site: "site\($0)", now: now) }

        #expect(admitted == [0, 1, 2, 3, 4])
    }

    @Test func oneSendPerSitePer24Hours() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var budget = BlockingReportBudget()
        #expect(budget.admit(site: "a", now: start))
        #expect(!budget.admit(site: "a", now: start.addingTimeInterval(60)))

        // The next launch reads the saved times.
        var nextLaunch = BlockingReportBudget(lastSent: budget.lastSent)
        #expect(!nextLaunch.admit(site: "a", now: start.addingTimeInterval(23 * 3_600)))
        #expect(nextLaunch.admit(site: "a", now: start.addingTimeInterval(BlockingReportBudget.perSiteInterval)))
    }

    @Test func aRefusedSiteDoesNotUseTheLaunchBudget() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var budget = BlockingReportBudget(lastSent: ["held": now])
        #expect(!budget.admit(site: "held", now: now))
        #expect((0..<5).allSatisfy { budget.admit(site: "site\($0)", now: now) })
    }

    @Test func expiredTimesAreForgottenAndAClockMovedBackDoesNotHold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var budget = BlockingReportBudget(lastSent: ["old": now.addingTimeInterval(-2 * BlockingReportBudget.perSiteInterval),
                                                     "future": now.addingTimeInterval(3_600)])
        #expect(budget.admit(site: "future", now: now))
        #expect(budget.lastSent.keys.sorted() == ["future"])
    }

    @Test func theSiteIdNamesTheKindAndEveryFrame() {
        let site = BlockingReportBudget.site(of: Self.fileRead)
        var otherCaller = Self.fileRead
        otherCaller.frames[2].offset += 4
        var otherKind = Self.fileRead
        otherKind.kind = .socketRead

        #expect(site.count == 16)
        #expect(site == BlockingReportBudget.site(of: Self.fileRead))
        #expect(site != BlockingReportBudget.site(of: otherCaller))
        #expect(site != BlockingReportBudget.site(of: otherKind))
        #expect(PrivacyLeakScanner(forbiddenTerms: []).kind(of: site) == nil)
    }
}

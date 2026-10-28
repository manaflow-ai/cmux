import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// The blocking detector's call sites in opt-in hang reports: one sample per site
/// with its kind, context and UUID + offset frames, nothing that names a path, the sites a launch
/// records before the setting is read kept, only in wire schema 3 (the deployed server refuses
/// them), and the crash-report budget of 5 per launch and 1 per site per 24 h.
struct BlockingSampleTests {
    /// A builder of the schema that carries blocking samples.
    private static let builder = HangReportBuilder(classifier: HangReportFixtures.classifier(),
                                                   resolver: HangReportFixtures.FakeResolver(), wireSchema: .v3)

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
        collector.noteBlocking(Self.fileRead)

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
        collector.noteBlocking(Self.fileRead)
        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: collector.drain(), metricKit: [])
        let body = try HangReport.encoder.encode(report)

        #expect(report.schema == HangReport.WireSchema.v3.rawValue)
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
        collector.noteBlocking(Self.fileRead)
        collector.noteBlocking(Self.fileRead)
        collector.noteBlocking(Self.semaphoreWait)

        #expect(collector.snapshot().blocking.map(\.blocking?.kind) == [.fileIO, .syncWait])
    }

    /// The body cap drops from the end of `hangs`: the shortest stall goes, never a blocking sample.
    @Test func theBodyCapKeepsTheBlockingSamples() throws {
        let fullStack = (0..<UInt64(HangSample.maxFrames)).map {
            HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 0x10_0000 + $0)
        }
        var aggregate = StallAggregate()
        for index in 0..<StallAggregate.maxSamples {
            aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 300 + index, frames: fullStack))
            aggregate.keep(HangSample(source: .watchdog, kind: .hang, durationMs: 3_000 + index, frames: fullStack))
        }
        for offset in 0..<UInt64(4) {
            aggregate.keep(.blockingSite(HangSample.Blocking(kind: .fileIO, context: .main),
                                         frames: [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: offset)]))
        }
        let built = Self.builder.build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])
        #expect(try HangReport.encoder.encode(built).count > HangReport.maxBodyBytes)

        let fitted = HangReportService.fitted(built)

        #expect(try HangReport.encoder.encode(fitted).count <= HangReport.maxBodyBytes)
        #expect(fitted.hangs.count < built.hangs.count)
        #expect(fitted.hangs.filter { $0.kind == .blocking }.count == 4)
        // What the cap dropped are the shortest stalls.
        let droppedStalls = Set(built.hangs.map(\.durationMs)).subtracting(fitted.hangs.map(\.durationMs))
        #expect(droppedStalls.allSatisfy { $0 < 300 + StallAggregate.maxSamples })
    }

    // MARK: the deployed server's schema (2) has no blocking samples

    @Test func theDeployedSchemaLeavesTheBlockingSamplesOut() throws {
        var aggregate = StallAggregate()
        aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 400, frames: [.other]))
        aggregate.keep(.blockingSite(HangSample.Blocking(kind: .fileIO, context: .main), frames: [.other]))
        let report = HangReportFixtures.builder().build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])

        #expect(HangReport.WireSchema.deployed == .v2)
        #expect(report.schema == 2)
        #expect(report.hangs.map(\.kind) == [.stall])
        #expect(HangReportServerRules.violations(in: try HangReport.encoder.encode(report)).isEmpty)
    }

    @Test func aCollectorForTheDeployedSchemaKeepsNoSite() throws {
        let collector = HangReportCollector(resolve: { _ in [] }, schedule: { $0() })
        collector.setEnabled(true)
        collector.noteBlocking(Self.fileRead)
        #expect(collector.snapshot().isEmpty)

        // A blocking sample a schema 3 build saved is not merged either.
        var saved = StallAggregate()
        saved.keep(.blockingSite(HangSample.Blocking(kind: .fileIO, context: .main), frames: [.other]))
        collector.merge(saved)
        #expect(collector.snapshot().isEmpty)
    }

    @Test func aSchema3ReportPassesTheServerRules() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteBlocking(Self.fileRead)
        collector.noteBlocking(BlockingViolation(kind: .syncWait, context: .pool, frames: Self.semaphoreWait.frames))
        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: collector.drain(), metricKit: [])

        #expect(report.schema == 3)
        #expect(HangReportServerRules.violations(in: try HangReport.encoder.encode(report)).isEmpty)
    }

    // MARK: the context

    @Test func aPoolSiteIsKeptWithItsContext() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteBlocking(Self.semaphoreWait)
        collector.noteBlocking(BlockingViolation(kind: .syncWait, context: .pool, frames: Self.semaphoreWait.frames))

        // The same stack on another thread is another site.
        #expect(collector.snapshot().blocking.compactMap(\.blocking) == [
            HangSample.Blocking(kind: .syncWait, context: .main),
            HangSample.Blocking(kind: .syncWait, context: .pool),
        ])
    }

    @Test func atMostMaxSamplesSitesAreKept() {
        let collector = Self.collector()
        collector.setEnabled(true)
        for offset in 0..<UInt64(StallAggregate.maxSamples + 3) {
            collector.noteBlocking(BlockingViolation(kind: .fileIO, frames: [
                BlockingFrame(imageUUID: Self.uuid(HangReportFixtures.appUUID), offset: offset),
            ]))
        }

        #expect(collector.snapshot().blocking.count == StallAggregate.maxSamples)
    }

    // MARK: before the setting is read (the detector's install replay)

    @Test func aSiteBeforeTheSettingIsReadIsKeptUntilReportsTurnOn() {
        let collector = Self.collector()
        collector.noteBlocking(Self.fileRead)  // replayed at install, before setEnabled
        collector.setEnabled(true)

        #expect(collector.snapshot().blocking.count == 1)
    }

    @Test func aSiteBeforeTheSettingIsReadIsDroppedWhenReportsAreOff() {
        let collector = Self.collector()
        collector.noteBlocking(Self.fileRead)
        collector.setEnabled(false)
        collector.noteBlocking(Self.semaphoreWait)

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
        let admitted0 = budget.admit(site: "a", now: start)
        #expect(admitted0)
        let admitted1 = budget.admit(site: "a", now: start.addingTimeInterval(60))
        #expect(!admitted1)

        // The next launch reads the saved times.
        var nextLaunch = BlockingReportBudget(lastSent: budget.lastSent)
        let admitted2 = nextLaunch.admit(site: "a", now: start.addingTimeInterval(23 * 3_600))
        #expect(!admitted2)
        let admitted3 = nextLaunch.admit(site: "a", now: start.addingTimeInterval(BlockingReportBudget.perSiteInterval))
        #expect(admitted3)
    }

    @Test func aRefusedSiteDoesNotUseTheLaunchBudget() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var budget = BlockingReportBudget(lastSent: ["held": now])
        let admitted4 = budget.admit(site: "held", now: now)
        #expect(!admitted4)
        let allAdmitted = (0..<5).allSatisfy { budget.admit(site: "site\($0)", now: now) }
        #expect(allAdmitted)
    }

    @Test func expiredTimesAreForgottenAndAClockMovedBackDoesNotHold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var budget = BlockingReportBudget(lastSent: ["old": now.addingTimeInterval(-2 * BlockingReportBudget.perSiteInterval),
                                                     "future": now.addingTimeInterval(3_600)])
        let admitted5 = budget.admit(site: "future", now: now)
        #expect(admitted5)
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

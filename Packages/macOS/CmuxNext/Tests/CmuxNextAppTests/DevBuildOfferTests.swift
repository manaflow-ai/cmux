@testable import CmuxNextUpdater
import Foundation
import Testing

/// A Dev-channel app offers a new Dev build on the bottom-left card by itself (Leo 2026-10-23:
/// "BUT i want it to be auto suggesting on the bottom left... that's the point"). With
/// `updates.offerDevBuilds` on and cmux in front, `dev-builds.json` beside the appcast is read
/// every few minutes with a conditional GET; a build newer than the running and staged ones starts
/// the background check that downloads it and shows it on the card. Off, nothing is read.
@MainActor @Suite(.serialized) struct DevBuildOfferTests {
    /// Answers each conditional GET from `answers` in turn (the last repeats) and records the ETag sent.
    final class FakeSidecar: ConditionalFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String?] = []
        var answers: [ConditionalResponse]
        init(_ answers: [ConditionalResponse]) { self.answers = answers }
        var fetches: Int { lock.withLock { sent.count } }
        var etagsSent: [String?] { lock.withLock { sent } }
        func fetch(_ url: URL, etag: String?) async throws -> ConditionalResponse {
            lock.withLock {
                sent.append(etag)
                return answers[min(sent.count - 1, answers.count - 1)]
            }
        }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func sidecar(newest build: String, etag: String) -> ConditionalResponse {
        let json = """
        {"schema":"cmux-dev-builds-v1","updated_at":"2027-01-15T08:00:00Z","bundle_id":"com.cmuxterm.app.nightly","builds":[
          {"build":"\(build)","version":"0.70.0","sha":"\(String(repeating: "a", count: 40))","built_at":"2027-01-15T07:58:00Z",
           "title":"Agent chat: a finished turn folds only its work","pr":24300,
           "url":"https://files-next.cmux.com/nightly-next/dev/\(build)/cmux.dmg","length":1000,"ed_signature":"c2ln",
           "minimum_system_version":"14.0"},
          {"build":"100","version":"0.69.0","sha":"\(String(repeating: "b", count: 40))","built_at":"2027-01-15T06:00:00Z",
           "title":"older","pr":null,"url":"https://files-next.cmux.com/nightly-next/dev/100/cmux.dmg","length":1000,
           "ed_signature":"c2ln","minimum_system_version":"14.0"}]}
        """
        return .changed(Data(json.utf8), etag: etag)
    }

    struct Harness {
        let updater: UpdaterService
        let clock: ManualClock
        let sidecar: FakeSidecar
        let checks: () -> Int
    }

    /// A NIGHTLY on build 100 following `ring`, nothing staged, cmux in front.
    static func make(ring: String = "dev", offer: Bool = true, answers: [ConditionalResponse]) -> Harness {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.dev-offer", shortVersion: "0.69.0", build: "100",
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast.xml", hasPublicKey: true)
        let defaults = UserDefaults(suiteName: "DevBuildOfferTests.\(UUID().uuidString)")!
        let clock = ManualClock()
        let sidecar = FakeSidecar(answers)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        var checks = 0
        updater.stagedRefresh.devBuilds.fetcher = sidecar
        updater.stagedRefresh.devBuilds.startBackgroundCheck = { checks += 1 }
        updater.stagedRefresh.devBuilds.isAppActive = { true }
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true, ring: ring, offerDevBuilds: offer)
        updater.start()
        return Harness(updater: updater, clock: clock, sidecar: sidecar, checks: { checks })
    }

    func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func aNewDevBuildIsOfferedWithNoManualCheck() async throws {
        let h = Self.make(answers: [Self.sidecar(newest: "500", etag: "\"v1\"")])
        try #require(await eventually { h.sidecar.fetches == 1 }, "dev-builds.json was not read when the watch started")
        #expect(await eventually { h.checks() == 1 }, "Dev build 500 is out but no background check started to offer it on the card")
        #expect(h.sidecar.etagsSent == [nil])
    }

    /// Every few minutes, a conditional GET with the last ETag; an unchanged sidecar (304) starts nothing.
    @Test func anUnchangedSidecarCostsOneConditionalGetAndOffersNothing() async throws {
        let h = Self.make(answers: [Self.sidecar(newest: "500", etag: "\"v1\""), .notModified])
        try #require(await eventually { h.checks() == 1 })
        try await h.clock.waitForSleeper()
        h.clock.advance(by: DevBuildWatch.baseInterval)
        try #require(await eventually { h.sidecar.fetches == 2 }, "no second read after the interval")
        #expect(h.sidecar.etagsSent == [nil, "\"v1\""], "the second read was not conditional on the first ETag")
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.checks() == 1, "an unchanged sidecar started another check")
    }

    /// The running build is the newest Dev build: nothing to offer.
    @Test func theNewestBuildRunningOffersNothing() async throws {
        let h = Self.make(answers: [Self.sidecar(newest: "100", etag: "\"v1\"")])
        try #require(await eventually { h.sidecar.fetches == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.checks() == 0)
    }

    /// Off (the default), or on another ring, the sidecar is never read.
    @Test func offOrOffTheDevRingNothingIsRead() async throws {
        let off = Self.make(offer: false, answers: [Self.sidecar(newest: "500", etag: "\"v1\"")])
        let nightly = Self.make(ring: "nightly", answers: [Self.sidecar(newest: "500", etag: "\"v1\"")])
        try await Task.sleep(for: .milliseconds(200))
        off.clock.advance(by: DevBuildWatch.baseInterval * 4)
        nightly.clock.advance(by: DevBuildWatch.baseInterval * 4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(off.sidecar.fetches == 0, "the setting is off but dev-builds.json was read")
        #expect(nightly.sidecar.fetches == 0, "the Nightly ring read dev-builds.json")
    }

    /// cmux in the background reads nothing; coming back to the front reads once at once.
    @Test func inTheBackgroundNothingIsReadUntilCmuxIsInFront() async throws {
        let h = Self.make(answers: [Self.sidecar(newest: "500", etag: "\"v1\"")])
        try #require(await eventually { h.sidecar.fetches == 1 })
        h.updater.stagedRefresh.devBuilds.appActivity(active: false, updater: h.updater)
        h.clock.advance(by: DevBuildWatch.maxInterval * 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sidecar.fetches == 1, "dev-builds.json was read while cmux was in the background")
        #expect(!h.updater.stagedRefresh.devBuilds.timer.isScheduled, "a timer stayed armed in the background")
        h.updater.stagedRefresh.devBuilds.minimumReadSpacing = .zero
        h.updater.stagedRefresh.devBuilds.appActivity(active: true, updater: h.updater)
        #expect(await eventually { h.sidecar.fetches == 2 }, "coming back to the front did not read dev-builds.json")
    }
}

import Foundation
import Testing
@testable import CmuxNextUpdater

/// Lawrence 2026-10-09: the update result was a wide plain card with only
/// "cmux Is Up to Date" that never went away. Now one model (``UpdateCard``)
/// gives the shared notice card an icon, a title, one short detail line and
/// the actions that apply; "up to date" hides itself on the injected clock,
/// and a found update offers Update and Release Notes without a check.
@MainActor
@Suite(.serialized) struct UpdateNoticeTests {
    static let version = "1.0.0-nightly.3752664687401", build = "3752664687401"

    private func service(clock: ManualClock = ManualClock()) -> UpdaterService {
        let defaults = UserDefaults(suiteName: "update-notice-\(UUID().uuidString)") ?? .standard
        let identity = AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: Self.build, short: Self.version,
                                                feed: "https://files-next.cmux.com/nightly-next/appcast.xml")
        return UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                              enableSparkle: false, clock: clock)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<10_000 where !done() { await Task.yield() }
    }

    @Test func upToDateIsANoticeWithItsVersionAndHidesItself() async throws {
        let clock = ManualClock()
        let updater = service(clock: clock)
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .note(.upToDate)
        #expect(updater.card == .note(.upToDate))
        let notice = try #require(updater.cardPresentation)
        #expect(notice.symbol == "checkmark.circle")
        #expect(notice.title == "cmux Is Up to Date")
        #expect(notice.detail == "Version \(Self.version), checked just now", "the nightly version already names its build")
        #expect(notice.actions.isEmpty && notice.dismissible)
        #expect(notice.dismissesAfter == UpdaterService.noteDuration)
        await clock.sleepers(atLeast: 1)
        clock.advance(by: UpdaterService.noteDuration)
        await settle { updater.card == nil }
        #expect(updater.card == nil, "the up-to-date notice hides itself")
    }

    @Test func aFailedCheckStaysWithTryAgainAndDetails() throws {
        let updater = service()
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .note(.checkFailed)
        let notice = try #require(updater.cardPresentation)
        #expect(notice.title == "Couldn't Check for Updates")
        #expect(notice.actions == [.retry, .details])
        #expect(notice.dismissesAfter == nil, "an error waits for the user")
        updater.dismissCard()
        #expect(updater.card == nil)
    }

    @Test func aFoundUpdateOffersUpdateAndReleaseNotesWithoutACheck() throws {
        let updater = service()
        updater.debugIndicatorPhase = .available(version: "1.0.0-nightly.3760000000001")
        #expect(updater.card == .available(version: "1.0.0-nightly.3760000000001"), "shown even though the user did not ask")
        let notice = try #require(updater.cardPresentation)
        #expect(notice.title == "cmux 1.0.0-nightly.3760000000001 Is Available")
        #expect(notice.detail == "You have \(Self.version).")
        #expect(notice.actions == [.update, .releaseNotes])
        #expect(notice.actions.map(\.title) == ["Update", "Release Notes"])
        #expect(updater.cardReleaseNotesURL != nil)
        updater.dismissCard()
        #expect(updater.card == nil, "dismissed for this version")
        updater.debugIndicatorPhase = .available(version: "1.0.0-nightly.3770000000001")
        #expect(updater.card != nil, "a newer version shows again")
    }

    @Test func aStagedUpdateIsNeverANotice() {
        let updater = service()
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .ready(version: "2")
        #expect(updater.card == nil, "the staged update card owns that state")
    }

    /// Task B (2026-10-09): the installed nightly-next build equals the
    /// newest feed item, so it is up to date; the next published run is
    /// offered. CFBundleVersion is `<run id><attempt>`, compared numerically.
    @Test func nightlyNextBuildsCompareByRunNumber() {
        let installed = Self.build
        let feed = [AppcastItem(version: "3752664687401"), AppcastItem(version: "3746432045701")]
        #expect(AppcastSelector.select(from: feed, currentBuild: installed, system: SystemVersion(major: 26))
            == .upToDate(latest: feed[0]))
        let next = AppcastItem(version: "3760012345601")
        #expect(AppcastSelector.select(from: feed + [next], currentBuild: installed, system: SystemVersion(major: 26))
            == .updateAvailable(next))
    }
}

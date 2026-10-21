@testable import CmuxNextUpdater
import Foundation
import Testing

/// After a relaunch, an install that did not take says so and why, instead of offering
/// "Restart to Update" again (2026-10-21: a restart that installed an old staged build looked
/// like a failure, and a real failure showed nothing). The record the old app writes names the
/// build it ran (`fromBuild`) and the build it installed (`toBuild`): this launch is `toBuild`
/// when the install worked, `fromBuild` when it did not.
@MainActor @Suite(.serialized) struct UpdateDidNotInstallTests {
    /// The running app is 1.0.0 (build 100), with `record` left by the previous launch.
    static func updater(record: WhatsNewLastUpdate?, staged: String? = nil) throws -> (UpdaterService, WhatsNewLastUpdateStore) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "UpdateDidNotInstallTests.\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        let store = WhatsNewLastUpdateStore(url: folder.appending(path: "last-update.json", directoryHint: .notDirectory))
        if let record { #expect(store.write(record)) }
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-did-not-install", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = try #require(UserDefaults(suiteName: "UpdateDidNotInstallTests.\(UUID().uuidString)"))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: true, lastUpdateStore: store)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        updater.stagedBuild = { staged }
        updater.whatsNew.load()
        updater.start()
        if let staged { updater.debugIndicatorPhase = .ready(version: versions[staged]) }
        return (updater, store)
    }

    static let versions = ["99": "0.9.9", "100": "1.0.0", "101": "1.0.1"]

    static func record(from: String, to: String, started: Bool, failure: String? = nil) -> WhatsNewLastUpdate {
        WhatsNewLastUpdate(fromVersion: versions[from]!, fromBuild: from, toVersion: versions[to]!, toBuild: to,
                           stagedAt: Date(timeIntervalSince1970: 1_800_000_000),
                           changelog: UpdateChangelog(version: versions[to]!, date: nil, lines: []),
                           installStartedAt: started ? Date(timeIntervalSince1970: 1_800_000_100) : nil, installFailure: failure)
    }

    @Test func anInstallThatLeftTheOldBuildRunningShowsWhy() throws {
        let reason = "cmux was still running 60 s after the install click."
        let (updater, _) = try Self.updater(record: Self.record(from: "100", to: "101", started: true, failure: reason))
        #expect(updater.card?.kind == "install_failed", "the failed install showed \(String(describing: updater.card))")
        let shown = try #require(updater.cardPresentation)
        #expect(shown.title.contains("1.0.1"), "\(shown.title)")
        #expect(shown.detail == reason)
        #expect(shown.actions.map(\.rawValue) == ["retry", "download_manually"])
        #expect(!updater.whatsNew.showsUpdatedCard, "the failed install reads as an update")
    }

    @Test func aFailedInstallWithNoRecordedErrorStillSaysItDidNotInstall() throws {
        let (updater, _) = try Self.updater(record: Self.record(from: "100", to: "101", started: true))
        #expect(updater.card?.kind == "install_failed")
        #expect(updater.cardPresentation?.detail?.isEmpty == false, "the failed install gives no reason")
    }

    /// The launch check stages the same (or a newer) build right away: the failure keeps the
    /// slot instead of "Restart to Update" coming straight back.
    @Test func theFailureShowsInsteadOfRestartToUpdate() throws {
        let (updater, _) = try Self.updater(record: Self.record(from: "100", to: "101", started: true), staged: "101")
        #expect(updater.readyCard == nil, "Restart to Update came back after a failed install")
        #expect(updater.card?.kind == "install_failed")
    }

    /// Staging alone writes the record; an update that never started installing (install on
    /// quit off, or replaced by a newer one) is no failure.
    @Test func anUpdateThatOnlyWaitedShowsNothing() throws {
        let (updater, store) = try Self.updater(record: Self.record(from: "100", to: "101", started: false))
        #expect(updater.card == nil)
        #expect(updater.whatsNew.failedInstall == nil)
        #expect((try? Data(contentsOf: store.url)) == nil, "the stale record stayed on disk")
    }

    @Test func theInstalledBuildShowsNoFailure() throws {
        let (updater, _) = try Self.updater(record: Self.record(from: "99", to: "100", started: true))
        #expect(updater.card == nil, "a successful update showed \(String(describing: updater.card))")
        #expect(updater.whatsNew.lastUpdate?.toBuild == "100")
        #expect(updater.whatsNew.showsUpdatedCard)
    }

    /// The restart worked and the launch check staged the next build at once: the staged card
    /// says the app updated, so a fresh "ready" card never reads as a failed restart.
    @Test func theNextUpdateAfterARestartSaysTheRestartWorked() throws {
        let (updater, _) = try Self.updater(record: Self.record(from: "99", to: "100", started: true), staged: "101")
        let card = try #require(updater.readyCard)
        #expect(card.title.contains("1.0.0"), "the card after a working restart reads \(card.title)")
        #expect(card.detail?.contains("1.0.1") == true, "the next update is not named: \(card.detail ?? "nil")")
        #expect(card.buttonTitle == UpdaterStrings.restartToUpdate)
    }

    /// A rollback to the build an update replaced is no failed install: the update's own
    /// launch keeps the record for its card, without the install start.
    @Test func aRollbackAfterAWorkingUpdateShowsNoFailure() throws {
        let (_, store) = try Self.updater(record: nil)
        #expect(store.write(Self.record(from: "100", to: "101", started: true)))
        guard case .installed? = store.take(running: "101") else {
            Issue.record("the update's own launch did not read it as installed")
            return
        }
        #expect(store.take(running: "100") == nil, "rolling back to 1.0.0 read as a failed install of 1.0.1")
    }
}

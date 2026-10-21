import Foundation
@testable import CmuxNextUpdater
import Testing

/// The staged update card offers only a build newer than the running one
/// (Leo 2026-10-20: right after NIGHTLY updated itself and relaunched, the card
/// said "Update Ready / Restart to Update" again with no version line; updates
/// should just install and never offer the version already running). A staged
/// item that is the running build or older, or one whose version is unknown,
/// shows no card, no footer pill and no ready circle.
@MainActor @Suite(.serialized) struct UpdateReadyNotNewerTests {
    /// The running app is 1.0.0 (build 100).
    static func updater(stagedBuild: String?) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-ready-not-newer", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "UpdateReadyNotNewerTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.stagedBuild = { stagedBuild }
        updater.notesLoader = { _ in nil }
        updater.start()
        return updater
    }

    @Test func theInstalledVersionOfferedAgainShowsNoCard() {
        let updater = Self.updater(stagedBuild: "100")
        updater.debugIndicatorPhase = .ready(version: "1.0.0")
        #expect(updater.readyCard == nil, "the running build was offered as an update")
        #expect(updater.footerPill == nil)
        #expect(updater.flow.phase == .hidden)
    }

    @Test func anOlderStagedBuildShowsNoCard() {
        let updater = Self.updater(stagedBuild: "99")
        updater.debugIndicatorPhase = .ready(version: "0.9.9")
        #expect(updater.readyCard == nil, "an older build was offered as an update")
        #expect(updater.footerPill == nil)
    }

    @Test func theRunningDisplayVersionWithNoBuildShowsNoCard() {
        let updater = Self.updater(stagedBuild: nil)
        updater.debugIndicatorPhase = .ready(version: "1.0.0")
        #expect(updater.readyCard == nil, "the running version was offered as an update")
        #expect(updater.footerPill == nil)
    }

    @Test func anUnknownStagedUpdateShowsNoCard() {
        let updater = Self.updater(stagedBuild: nil)
        updater.debugIndicatorPhase = .ready(version: nil)
        #expect(updater.readyCard == nil, "Update Ready showed for an update of unknown version")
        #expect(updater.footerPill == nil)
        updater.send(.checkRequested)
        #expect(updater.readyCard == nil, "a check while nothing newer is staged showed Update Ready")
    }

    @Test func aNewerStagedBuildStillShowsTheCard() {
        let updater = Self.updater(stagedBuild: "101")
        updater.debugIndicatorPhase = .ready(version: "1.0.1")
        #expect(updater.readyCard != nil, "a newer staged build showed no card")
        #expect(updater.stagedVersion == "1.0.1")
        #expect(updater.footerPill == .ready)
    }
}

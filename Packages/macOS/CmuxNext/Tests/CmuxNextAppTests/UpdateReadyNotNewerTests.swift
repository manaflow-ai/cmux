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

    /// Hiding the card is not enough: Sparkle's install session for that
    /// build stays open, so quitting would install the running build again
    /// (install on quit no longer cancels a phase that shows nothing) and
    /// Check for Updates would be ignored behind it. A staged update that is
    /// not newer has its installer cancelled (Skip on Sparkle's held ready
    /// reply, which records no skipped version) as soon as it shows.
    @Test func aStagedBuildThatIsNotNewerHasItsInstallerCancelled() {
        for (staged, version) in [("100", "1.0.0"), ("99", "0.9.9")] {
            let updater = Self.updater(stagedBuild: staged)
            let cancels = Counter()
            updater.cancelStaged = { cancels.count += 1; return true }
            updater.debugIndicatorPhase = .ready(version: version)
            #expect(cancels.count > 0, "build \(staged)'s staged installer still runs: quitting installs it again")
        }
    }

    /// Only a known build number proves a staged update is not newer. One of
    /// unknown version, or known only by its display version, can be a newer
    /// build the user asked for (Install Update with automatic downloads off
    /// answers Sparkle's prompt itself), so it stays hidden but keeps its
    /// installer.
    @Test func aStagedUpdateWithNoBuildNumberKeepsItsInstaller() {
        for version in [nil, "1.0.0", "1.0.1"] as [String?] {
            let updater = Self.updater(stagedBuild: nil)
            let cancels = Counter()
            updater.cancelStaged = { cancels.count += 1; return true }
            updater.debugIndicatorPhase = .ready(version: version)
            updater.checkForUpdates()
            #expect(cancels.count == 0, "a staged update of version \(version ?? "unknown") with no build number was cancelled")
        }
    }

    /// The installer is cancelled once: the log says so only when Sparkle
    /// held one (the cancel reports it), never again for the same item, and
    /// never when nothing was held.
    @Test func theCancelIsLoggedOnlyWhenAnInstallerWasHeld() {
        let line = "is not newer than build 100: cancelling its installer"
        let updater = Self.updater(stagedBuild: "100")
        let calls = Counter()
        updater.cancelStaged = { calls.count += 1; return calls.count == 1 }
        updater.debugIndicatorPhase = .ready(version: "1.0.0")
        updater.checkForUpdates()
        updater.send(.checkRequested)
        #expect(updater.log.recent.filter { $0.contains(line) }.count == 1, "\(updater.log.recent)")

        let nothingHeld = Self.updater(stagedBuild: "100")
        nothingHeld.cancelStaged = { false }
        nothingHeld.debugIndicatorPhase = .ready(version: "1.0.0")
        #expect(!nothingHeld.log.recent.contains { $0.contains(line) }, "logged a cancel with no installer held")
    }

    @Test func aNewerStagedBuildKeepsItsInstaller() {
        let updater = Self.updater(stagedBuild: "101")
        let cancels = Counter()
        updater.cancelStaged = { cancels.count += 1; return true }
        updater.debugIndicatorPhase = .ready(version: "1.0.1")
        updater.checkForUpdates()
        #expect(cancels.count == 0, "a newer staged update was cancelled")
    }

    @Test func aNewerStagedBuildStillShowsTheCard() {
        let updater = Self.updater(stagedBuild: "101")
        updater.debugIndicatorPhase = .ready(version: "1.0.1")
        #expect(updater.readyCard != nil, "a newer staged build showed no card")
        #expect(updater.stagedVersion == "1.0.1")
        #expect(updater.footerPill == .ready)
    }
}

/// Counts calls from a stubbed closure.
@MainActor private final class Counter {
    var count = 0
}

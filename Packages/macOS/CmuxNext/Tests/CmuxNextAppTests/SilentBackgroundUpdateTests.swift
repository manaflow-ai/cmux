import CmuxNextWakeups
import Foundation
@testable import CmuxNextUpdater
import Testing

/// A background update check is invisible (Lawrence 2026-10-20: "if there is
/// a background check for updates, it should not be visible to the user ...
/// a bottom-left toast or card ... should only be shown if there is actually
/// an update and it has finished downloading"). A scheduled check, its
/// download, its "up to date" and its failure show nothing; only a staged
/// (downloaded and verified) update shows the one bottom-left card. A check
/// the person asks for still shows its progress and result.
@MainActor @Suite(.serialized) struct SilentBackgroundUpdateTests {
    /// A DEV build's updater: no Sparkle, no defaults of the user's. The
    /// phases come through ``UpdaterService/debugIndicatorPhase``, which feeds
    /// the gate exactly as Sparkle's flow does.
    static func updater() -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.silent-background-update", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(suiteName: "SilentBackgroundUpdateTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, work: BackgroundWork(label: "test.updater"), deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    @Test func aBackgroundCheckDownloadAndResultShowNothing() {
        let updater = Self.updater()
        for phase: UpdateIndicatorPhase in [.checking, .downloading(.starting), .downloading(UpdateTransfer(stage: .downloading, fraction: 0.4)), .note(.upToDate),
                                            .checking, .note(.checkFailed)] {
            updater.debugIndicatorPhase = phase
            #expect(updater.card == nil, "a background \(phase) showed \(String(describing: updater.card))")
            #expect(updater.readyCard == nil, "a background \(phase) showed the staged update card")
        }
    }

    @Test func aBackgroundCheckAfterTheUsersUnclosedFailureShowsNothing() {
        let updater = Self.updater()
        // The person asked; the check failed and its card stays (a failure waits for its x).
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == .checking)
        updater.debugIndicatorPhase = .note(.checkFailed)
        #expect(updater.card == .note(.checkFailed))
        // Later the scheduled check runs by itself: the person did not ask for this one.
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == nil, "the scheduled check showed \(String(describing: updater.card))")
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5))
        #expect(updater.card == nil, "the scheduled download showed \(String(describing: updater.card))")
        updater.debugIndicatorPhase = .note(.checkFailed)
        #expect(updater.card == nil, "the scheduled check's failure showed \(String(describing: updater.card))")
    }

    @Test func aCheckThatEndsWithNothingEndsTheRequest() {
        let updater = Self.updater()
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == .checking)
        // The check ended without a result (cancelled): the next scheduled check stays silent.
        updater.debugIndicatorPhase = .hidden
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == nil, "the scheduled check showed \(String(describing: updater.card))")
    }

    @Test func theUsersCheckWhileABackgroundCheckRunsShowsItsProgressAndResultOnce() {
        let updater = Self.updater()
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == nil)
        updater.send(.checkRequested)
        #expect(updater.card == .checking, "the person's check joined the running one but showed nothing")
        updater.debugIndicatorPhase = .note(.upToDate)
        #expect(updater.card == .note(.upToDate))
        updater.noteExpired()
        updater.debugIndicatorPhase = .hidden
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == nil, "the next scheduled check showed \(String(describing: updater.card))")
    }

    @Test func aFoundUpdateWaitsSilentlyWhileAutomaticDownloadsAreOn() {
        let updater = Self.updater()
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true)
        // Automatic downloads on, deferred (Low Data Mode, metered link): no card until it is downloaded.
        updater.debugIndicatorPhase = .available(version: "2.0")
        #expect(updater.card == nil, "a found, not yet downloaded update showed \(String(describing: updater.card))")
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5))
        #expect(updater.card == nil)
        updater.debugIndicatorPhase = .ready(version: "2.0")
        #expect(updater.readyCard != nil, "the downloaded update shows no card")
        #expect(updater.readyCard?.isInstalling == false, "the staged card's button is disabled")
    }

    @Test func aFoundUpdateStillShowsWhenThePersonTurnedAutomaticDownloadsOff() {
        let updater = Self.updater()
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: false)
        updater.debugIndicatorPhase = .available(version: "2.0")
        #expect(updater.card == .available(version: "2.0"), "with downloads off the person never learns of the update")
    }

    @Test func theUsersCheckStillShowsAFoundUpdate() {
        let updater = Self.updater()
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true)
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .checking
        updater.debugIndicatorPhase = .available(version: "2.0")
        #expect(updater.card == .available(version: "2.0"), "the person asked and the found update showed nothing")
    }

    @Test func aBackgroundFailureWhileAnUpdateIsStagedOpensNoSheet() {
        let updater = Self.updater()
        var sheets = 0
        updater.presentUpdateUI = { sheets += 1 }
        updater.debugIndicatorPhase = .ready(version: "2.0")
        updater.debugIndicatorPhase = .note(.checkFailed)
        #expect(sheets == 0, "a failure nobody clicked for opened the update sheet")
        #expect(updater.card == nil)
    }

    @Test func aFailedInstallTheUserClickedStillOpensTheSheet() {
        let updater = Self.updater()
        var sheets = 0
        updater.presentUpdateUI = { sheets += 1 }
        updater.debugIndicatorPhase = .ready(version: "2.0")
        updater.debugIndicatorPhase = .installing
        updater.debugIndicatorPhase = .note(.checkFailed)
        #expect(sheets == 1, "the failed install ended in silence")
    }
}

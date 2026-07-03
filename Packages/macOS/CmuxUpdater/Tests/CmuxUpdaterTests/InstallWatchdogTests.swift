import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Tests for the install watchdog's decision logic in ``InstallWatchdog``.
///
/// The watchdog exists to guarantee the user is never left staring at a silent "Update Available"
/// pill after clicking Install: if the flow never reaches downloading/installing (or another
/// visible outcome) within ``installWatchdogTimeout``, a visible "Update Didn't
/// Start" error is surfaced. These tests pin the two pure predicates that drive arming/firing so
/// the classification can't silently drift.
@MainActor
@Suite struct InstallWatchdogTests {
    private let watchdog = InstallWatchdog(clock: SystemUpdateClock(), timeout: installWatchdogTimeout)

    private func updateAvailable(_ version: String = "0.64.16") -> UpdateState {
        let item = SUAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]) ?? SUAppcastItem.empty()
        return .updateAvailable(.init(appcastItem: item, reply: { _ in }))
    }

    private var everyState: [UpdateState] {
        [
            .idle,
            .permissionRequest(.init(request: SPUUpdatePermissionRequest(systemProfile: []), reply: { _ in })),
            .checking(.init(cancel: {})),
            updateAvailable(),
            .notFound(.init(acknowledgement: {})),
            .error(.init(error: NSError(domain: "t", code: 1), retry: {}, dismiss: {})),
            .downloading(.init(cancel: {}, expectedLength: 100, progress: 10)),
            .extracting(.init(progress: 0.5)),
            .installing(.init(retryTerminatingApplication: {}, dismiss: {})),
        ]
    }

    /// The watchdog reports a stall for the states an armed deadline can legitimately catch the
    /// flow in with nothing downloading: mid-check, an unacted "Update Available" (the states the
    /// double-idle bug got stuck in), and `.idle` (the pre-check stall where the delayed re-check
    /// was dropped — every benign idle disarms before the deadline can fire).
    @Test func stalledForNonProgressingStates() {
        for state in everyState {
            let stalled = watchdog.installAttemptStalled(state)
            switch state {
            case .checking, .updateAvailable, .idle:
                #expect(stalled, "\(state) should count as stalled")
            default:
                #expect(!stalled, "\(state) should NOT count as stalled")
            }
        }
    }

    /// Download/extract/install progress and clearly-communicated terminals (notFound/error)
    /// disarm the watchdog; idle/permissionRequest/checking/updateAvailable do not.
    @Test func resolvedForProgressAndVisibleTerminals() {
        for state in everyState {
            let resolved = watchdog.installAttemptResolved(state)
            switch state {
            case .downloading, .extracting, .installing, .notFound, .error:
                #expect(resolved, "\(state) should resolve/disarm the watchdog")
            default:
                #expect(!resolved, "\(state) should NOT resolve the watchdog")
            }
        }
    }

    /// A state is never simultaneously "stalled" and "resolved": the two predicates must not
    /// overlap, or arming and firing would race.
    @Test func stalledAndResolvedAreMutuallyExclusive() {
        for state in everyState {
            #expect(!(watchdog.installAttemptStalled(state) && watchdog.installAttemptResolved(state)))
        }
    }

    /// The watchdog is bound to the attempt that armed it: the coordinator ending its watch
    /// without a `.confirmInstall` hand-off (cancelled check, notFound, error) ends the watchdog's
    /// watch too. Only an actual install hand-off — or the coordinator still being mid-flow —
    /// keeps the deadline armed.
    @Test func attemptEndedWithoutInstallTruthTable() {
        let actions: [AttemptUpdateCoordinator.Action] = [.none, .startFreshCheck, .confirmInstall]
        for action in actions {
            // While the coordinator is still monitoring, the attempt is alive regardless of action.
            #expect(!watchdog.attemptEndedWithoutInstall(action: action, isCoordinatorMonitoring: true))
            let expected = action != .confirmInstall
            #expect(watchdog.attemptEndedWithoutInstall(action: action, isCoordinatorMonitoring: false) == expected)
        }
    }

    /// User cancels the attempt's fresh check (checking → idle): the coordinator goes inactive
    /// without confirming, which must read as "attempt ended" so the controller disarms — a
    /// leftover deadline would fire a spurious "Update Didn't Start" over the user's next,
    /// unrelated check.
    @Test func cancelledFreshCheckEndsTheWatchdogsWatch() {
        var coordinator = AttemptUpdateCoordinator()
        #expect(coordinator.requestInstallLatest(currentState: updateAvailable()) == .startFreshCheck)
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        let action = coordinator.handleStateChange(.idle)
        #expect(action == .none)
        #expect(watchdog.attemptEndedWithoutInstall(
            action: action,
            isCoordinatorMonitoring: coordinator.isMonitoring
        ))
    }

    /// The successful hand-off (`.confirmInstall`) also drops the coordinator to inactive, but the
    /// watchdog must stay armed there: it still guards the window between replying `.install` and
    /// Sparkle visibly progressing to downloading.
    @Test func confirmInstallHandOffKeepsWatchdogArmed() {
        var coordinator = AttemptUpdateCoordinator()
        #expect(coordinator.requestInstallLatest(currentState: .idle) == .startFreshCheck)
        #expect(coordinator.handleStateChange(.checking(.init(cancel: {}))) == .none)
        let action = coordinator.handleStateChange(updateAvailable())
        #expect(action == .confirmInstall)
        #expect(!watchdog.attemptEndedWithoutInstall(
            action: action,
            isCoordinatorMonitoring: coordinator.isMonitoring
        ))
    }

    /// The watchdog error offers the direct-download recovery (the in-app path just proved it
    /// can't start), while the transient "updater not ready" error does not.
    @Test func watchdogErrorOffersManualDownload() {
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let notReady = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.updaterNotReadyCode)
        let recovery = UpdateManualDownloadRecovery()
        #expect(recovery.url(for: didNotStart) != nil)
        #expect(recovery.url(for: notReady) == nil)
    }

    /// The manual-download recovery routes to the failing build's own channel: a nightly feed
    /// gets the nightly release page, everything else the latest stable DMG. A NIGHTLY user must
    /// never be pointed at a stable download as the fix for a nightly install failure.
    @Test func manualDownloadRoutesToTheActiveChannel() throws {
        let didNotStart = NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode)
        let nightlyFeed = "https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast.xml"
        let recovery = UpdateManualDownloadRecovery()

        let nightlyURL = try #require(recovery.url(for: didNotStart, feedURLString: nightlyFeed))
        #expect(nightlyURL.absoluteString.contains("/nightly"))
        #expect(!nightlyURL.absoluteString.contains("latest/download"))

        let stableURL = try #require(recovery.url(for: didNotStart, feedURLString: "https://cmux.com/appcast.xml"))
        #expect(stableURL.absoluteString.contains("latest/download"))

        // Sparkle's own install failures route by channel the same way.
        let sparkleInstallFailure = NSError(domain: SUSparkleErrorDomain, code: 4005)
        let sparkleNightlyURL = try #require(recovery.url(for: sparkleInstallFailure, feedURLString: nightlyFeed))
        #expect(sparkleNightlyURL.absoluteString.contains("/nightly"))
    }

    /// An unrecognized cmux.update code renders the generic failure title instead of silently
    /// masquerading as "Updater Not Ready".
    @Test func unknownCmuxUpdateCodeFallsBackToGenericTitle() {
        let unknown = NSError(domain: UpdateStateModel.updateErrorDomain, code: 999)
        #expect(UpdateStateModel.userFacingErrorTitle(for: unknown) == "Update Failed")
    }

    /// The watchdog error renders with its own copy, not the generic "Update Failed" catch-all.
    @Test func watchdogErrorRendersDedicatedCopy() {
        let error = NSError(
            domain: UpdateStateModel.updateErrorDomain,
            code: UpdateStateModel.installDidNotStartCode,
            userInfo: [NSLocalizedDescriptionKey: "cmux couldn’t start the update. Check your internet connection and try again."]
        )
        let title = UpdateStateModel.userFacingErrorTitle(for: error)
        let message = UpdateStateModel.userFacingErrorMessage(for: error)
        #expect(title == "Update Didn’t Start")
        #expect(message.contains("couldn’t start the update"))
        #expect(title != "Update Failed")
    }
}

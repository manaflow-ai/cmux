import Testing
@testable import CmuxUpdaterCore

/// Tests for the install watchdog's decision logic in ``InstallWatchdog``.
///
/// The watchdog exists to guarantee the user is never left staring at a silent "Update Available"
/// pill after clicking Install: if the flow never reaches downloading/installing (or another
/// visible outcome) within ``InstallWatchdog/defaultTimeout``, a visible "Update Didn't
/// Start" error is surfaced. These tests pin the two pure predicates that drive arming/firing so
/// the classification can't silently drift.
@MainActor
@Suite struct InstallWatchdogTests {
    private let watchdog = InstallWatchdog(clock: SystemUpdateClock())

    /// The watchdog reports a stall for every accepted-install phase that has not reached download
    /// progress, plus unattributed idle (every causal user cancellation disarms first).
    @Test func stalledForNonProgressingStates() {
        for state in UpdateLifecyclePhase.allCases {
            let stalled = watchdog.installAttemptStalled(state)
            switch state {
            case .preparingCheck, .checking, .updateAvailable, .startingDownload, .idle:
                #expect(stalled, "\(state) should count as stalled")
            default:
                #expect(!stalled, "\(state) should NOT count as stalled")
            }
        }
    }

    /// Download/extract/install progress and clearly-communicated terminals (notFound/error)
    /// disarm the watchdog; idle/permissionRequest/preparing/checking/starting do not.
    @Test func resolvedForProgressAndVisibleTerminals() {
        for state in UpdateLifecyclePhase.allCases {
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
        for state in UpdateLifecyclePhase.allCases {
            #expect(!(watchdog.installAttemptStalled(state) && watchdog.installAttemptResolved(state)))
        }
    }

    /// The watchdog is bound to the attempt that armed it: the coordinator ending its watch
    /// without a `.confirmInstall` hand-off (cancelled check, notFound, error) ends the watchdog's
    /// watch too. Only an actual install hand-off — or the coordinator still being mid-flow —
    /// keeps the deadline armed.
    @Test func attemptEndedWithoutInstallTruthTable() {
        let actions: [AttemptUpdateCoordinator.Action] = [.none, .startFreshCheck, .confirmInstall, .installFailed]
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
        #expect(coordinator.requestInstallLatest(currentState: .updateAvailable) == .startFreshCheck)
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking) == .none)
        coordinator.cancel()
        let action = AttemptUpdateCoordinator.Action.none
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
        coordinator.didStartFreshCheck()
        #expect(coordinator.handleStateChange(.checking) == .none)
        let action = coordinator.handleStateChange(.updateAvailable)
        #expect(action == .confirmInstall)
        #expect(!watchdog.attemptEndedWithoutInstall(
            action: action,
            isCoordinatorMonitoring: coordinator.isMonitoring
        ))
    }
}

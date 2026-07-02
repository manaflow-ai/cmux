import Testing
@testable import CmuxUpdater

/// Regression coverage for the download-phase transient-retry auto-confirm contract (a follow-up to
/// issue #5632's retry work and the issue #6366 re-resolve flow).
///
/// When a Sparkle download/extract/install phase hits a transient failure, the retry must re-arm the
/// attempt coordinator so the update the retried check finds is auto-confirmed and installation
/// continues silently — it must NOT fall back to a bare check that surfaces a fresh "Update
/// Available" prompt (which strands the interrupted install).
///
/// ``UpdateController`` owns a live `SPUUpdater`, so the retry *decision* is factored into the pure
/// ``UpdateController/transientRetryPlan(preservingInstallIntent:coordinatorIsMonitoring:)`` and
/// asserted here. The surrounding links of the chain are covered separately: the driver emitting a
/// preserve-intent retry from a download phase (`UpdateDriverRetryTests`), and an armed coordinator
/// confirming the next resolved update (`AttemptUpdateCoordinatorTests`).
@Suite struct UpdateControllerTransientRetryPlanTests {
    /// THE FIX: a preserved-intent retry that arrives before the coordinator is monitoring must
    /// re-arm the coordinator (auto-confirm), not fall back to a bare check that prompts.
    @Test func downloadPhaseRetryWithoutMonitoringRearmsCoordinator() {
        let plan = UpdateController.transientRetryPlan(
            preservingInstallIntent: true,
            coordinatorIsMonitoring: false
        )
        #expect(plan == .rearmConfirmedInstall)
    }

    /// An already-monitored retry just restarts the coordinator's in-flight check, regardless of the
    /// driver's `preservingInstallIntent` flag.
    @Test func monitoredRetryRestartsMonitoredCheck() {
        #expect(
            UpdateController.transientRetryPlan(preservingInstallIntent: false, coordinatorIsMonitoring: true)
                == .restartMonitoredCheck
        )
        #expect(
            UpdateController.transientRetryPlan(preservingInstallIntent: true, coordinatorIsMonitoring: true)
                == .restartMonitoredCheck
        )
    }

    /// A plain transient retry (no install intent, not monitoring) runs an ordinary fresh check.
    @Test func plainRetryRunsPlainCheck() {
        #expect(
            UpdateController.transientRetryPlan(preservingInstallIntent: false, coordinatorIsMonitoring: false)
                == .plainCheck
        )
    }
}

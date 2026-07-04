import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Tests for the bounded readiness-wait continuation decision,
/// ``UpdateController/ReadinessWaitDecision``.
///
/// Regression (autoreview follow-up to issue #5632): the readiness wait is shared by every check
/// that must wait for `canCheckForUpdates`. The transient-retry work guarded it to stop unless the
/// model was `.checking`, which also aborted `attemptUpdate()`'s install-from-`.updateAvailable`
/// re-resolution (issue #6366) whenever Sparkle was briefly not ready — the user's Install then did
/// nothing until some unrelated state change occurred. The wait must keep polling for any pending
/// state and stop only when the user cancels the pending check back to `.idle`.
@MainActor
@Suite struct UpdateControllerReadinessWaitTests {
    private var updateAvailable: UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), reply: { _ in }))
    }

    /// `attemptUpdate()` enters the readiness wait while the model is still the `.updateAvailable`
    /// prompt it is re-resolving (issue #6366). The wait must keep polling for readiness so the fresh
    /// install check actually runs once Sparkle is ready — not abort and strand the Install action.
    @Test func keepsWaitingWhileInstallPromptReResolves() {
        #expect(UpdateController.ReadinessWaitDecision(modelState: updateAvailable) == .keepPolling)
    }

    /// A plain manual check or a transient-retry pill parks the model in `.checking` while waiting
    /// for readiness. The wait must keep polling.
    @Test func keepsWaitingWhileCheckingPillAwaitsReadiness() {
        #expect(UpdateController.ReadinessWaitDecision(modelState: .checking(.init(cancel: {}))) == .keepPolling)
    }

    /// Cancelling the pending check returns the model to `.idle`. The wait must stop, so readiness
    /// arriving later does not resurrect a check the user dismissed (the retry-pill Cancel, task #12).
    @Test func stopsWaitingWhenPendingCheckIsCancelledToIdle() {
        #expect(UpdateController.ReadinessWaitDecision(modelState: .idle) == .stop)
    }
}

import CmuxSocketControl
import Darwin
import Testing

@testable import CmuxControlSocket

@Suite struct SocketListenerPolicyAcceptTests {
    let policy = SocketListenerPolicy()

    @Test func acceptErrorClassificationBucketsExpectedErrnos() {
        #expect(policy.acceptErrorClassification(errnoCode: EINTR) == .immediateRetry)
        #expect(policy.acceptErrorClassification(errnoCode: ECONNABORTED) == .immediateRetry)
        #expect(policy.acceptErrorClassification(errnoCode: EMFILE) == .resourcePressure)
        #expect(policy.acceptErrorClassification(errnoCode: ENOMEM) == .resourcePressure)
        #expect(policy.acceptErrorClassification(errnoCode: EBADF) == .fatal)
        #expect(policy.acceptErrorClassification(errnoCode: EINVAL) == .fatal)
    }

    @Test func classificationRawValuesAreStableTelemetryIdentifiers() {
        #expect(SocketAcceptErrorClassification.immediateRetry.rawValue == "immediate_retry")
        #expect(SocketAcceptErrorClassification.resourcePressure.rawValue == "resource_pressure")
        #expect(SocketAcceptErrorClassification.fatal.rawValue == "fatal")
        #expect(SocketAcceptErrorClassification.retryWithBackoff.rawValue == "retry_with_backoff")
    }

    @Test func acceptErrorPolicySignalsRearmOnlyForFatalErrors() {
        #expect(policy.shouldRearmListener(forAcceptErrnoCode: EBADF))
        #expect(policy.shouldRearmListener(forAcceptErrnoCode: ENOTSOCK))
        #expect(!policy.shouldRearmListener(forAcceptErrnoCode: EMFILE))
        #expect(!policy.shouldRearmListener(forAcceptErrnoCode: EINTR))
    }

    @Test func acceptErrorPolicyRearmsAfterPersistentFailures() {
        #expect(!policy.shouldRearm(consecutiveFailures: 0))
        #expect(!policy.shouldRearm(consecutiveFailures: 49))
        #expect(policy.shouldRearm(consecutiveFailures: 50))
        #expect(policy.shouldRearm(consecutiveFailures: 120))
    }

    @Test func acceptFailureBackoffIsExponentialAndCapped() {
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 0) == 0)
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 1) == 10)
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 2) == 20)
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 6) == 320)
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 12) == 5_000)
        #expect(policy.acceptFailureBackoffMilliseconds(consecutiveFailures: 50) == 5_000)
    }

    @Test func acceptFailureRearmDelayAppliesMinimumThrottle() {
        #expect(policy.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 0) == 100)
        #expect(policy.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 1) == 100)
        #expect(policy.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 2) == 100)
        #expect(policy.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 6) == 320)
        #expect(policy.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 12) == 5_000)
    }

    @Test func acceptFailureRecoveryActionResumesAfterDelayForTransientErrors() {
        #expect(
            policy.acceptFailureRecoveryAction(errnoCode: EPROTO, consecutiveFailures: 1)
                == .resumeAfterDelay(delayMs: 10)
        )
        #expect(
            policy.acceptFailureRecoveryAction(errnoCode: EMFILE, consecutiveFailures: 3)
                == .resumeAfterDelay(delayMs: 40)
        )
    }

    @Test func acceptFailureRecoveryActionRearmsForFatalAndPersistentFailures() {
        #expect(
            policy.acceptFailureRecoveryAction(errnoCode: EBADF, consecutiveFailures: 1)
                == .rearmAfterDelay(delayMs: 100)
        )
        #expect(
            policy.acceptFailureRecoveryAction(errnoCode: EPROTO, consecutiveFailures: 50)
                == .rearmAfterDelay(delayMs: 5_000)
        )
    }

    @Test func acceptFailureRecoveryActionRetriesImmediatelyForTransientAcceptErrnos() {
        #expect(
            policy.acceptFailureRecoveryAction(errnoCode: EINTR, consecutiveFailures: 10)
                == .retryImmediately
        )
        #expect(policy.acceptFailureRecoveryAction(errnoCode: EINTR, consecutiveFailures: 10).delayMs == 0)
    }

    @Test func acceptFailureBreadcrumbSamplingPrefersEarlyAndPowerOfTwoMilestones() {
        #expect(policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 1))
        #expect(policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 2))
        #expect(policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 3))
        #expect(!policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 5))
        #expect(policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 8))
        #expect(!policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 9))
        #expect(policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 16))
        #expect(!policy.shouldEmitAcceptFailureBreadcrumb(consecutiveFailures: 0))
    }

    @Test func recoveryActionDebugLabelsAreStableTelemetryIdentifiers() {
        #expect(AcceptFailureRecoveryAction.retryImmediately.debugLabel == "retry_immediately")
        #expect(AcceptFailureRecoveryAction.resumeAfterDelay(delayMs: 1).debugLabel == "resume_after_delay")
        #expect(AcceptFailureRecoveryAction.rearmAfterDelay(delayMs: 1).debugLabel == "rearm_after_delay")
    }
}

@Suite struct SocketListenerPolicyUnlinkTests {
    let policy = SocketListenerPolicy()

    @Test func acceptLoopCleanupUnlinkPolicySkipsDuringListenerStartup() {
        #expect(
            !policy.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: true
            )
        )
        #expect(
            !policy.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: false,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
        #expect(
            !policy.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: true,
                activeGeneration: 7,
                listenerStartInProgress: false
            )
        )
        #expect(
            policy.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
    }

    @Test func listenerStopUnlinkPolicyRequiresSameBoundSocketIdentity() {
        let original = SocketPathIdentity(device: 1, inode: 10)
        let recreated = SocketPathIdentity(device: 1, inode: 11)

        #expect(
            policy.shouldUnlinkSocketPathAfterListenerStop(
                currentIdentity: original,
                boundIdentity: original
            )
        )
        #expect(
            !policy.shouldUnlinkSocketPathAfterListenerStop(
                currentIdentity: recreated,
                boundIdentity: original
            )
        )
        #expect(
            !policy.shouldUnlinkSocketPathAfterListenerStop(
                currentIdentity: nil,
                boundIdentity: original
            )
        )
        #expect(
            !policy.shouldUnlinkSocketPathAfterListenerStop(
                currentIdentity: recreated,
                boundIdentity: nil
            )
        )
    }
}

@Suite struct SocketListenerPolicyFallbackTests {
    let policy = SocketListenerPolicy()

    @Test func stableSocketBindPermissionFailureFallsBackToUserScopedSocket() {
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            ) == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        )
    }

    @Test func nonStableSocketBindFailureDoesNotFallback() {
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: "/tmp/cmux-debug.sock",
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            ) == nil
        )
    }

    @Test func stableSocketLockFailureFallsBackToUserScopedSocket() {
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "lock",
                errnoCode: EWOULDBLOCK,
                currentUserID: 501
            ) == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        )
    }

    @Test(arguments: [
        ("create_lock_directory", EACCES),
        ("open_lock", EACCES),
        ("open_lock", ELOOP),
        ("open_lock", EINVAL),
        ("open_lock", EMLINK),
        ("existing_path", EEXIST),
        ("stat_existing_path", EACCES),
    ] as [(String, Int32)])
    func stableSocketPreparationFailuresFallBackToUserScopedSocket(stage: String, errnoCode: Int32) {
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: stage,
                errnoCode: errnoCode,
                currentUserID: 501
            ) == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        )
    }

    @Test func unrelatedStagesDoNotFallback() {
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "listen",
                errnoCode: EACCES,
                currentUserID: 501
            ) == nil
        )
        #expect(
            policy.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "bind",
                errnoCode: ENOMEM,
                currentUserID: 501
            ) == nil
        )
    }
}

import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Deterministic end-to-end replays of the update reaction pipeline: a real ``UpdateController``
/// (reaction task, ``AttemptUpdateCoordinator``, ``InstallWatchdog``, prompt dismissal) driven
/// through a fake ``UpdaterHandle`` and a deadline-controlled clock, with Sparkle's emissions
/// replayed onto the model in the same order as Sparkle's production callbacks.
///
/// The real Sparkle install path only runs in release-channel builds (DEV builds suppress the
/// appcast), so this harness is the pre-merge regression surface for the lifecycle between an
/// accepted install and Sparkle's download callback.
@MainActor
@Suite struct UpdateControllerPipelineTests {
    private func updateAvailable(_ version: String, replyingInto box: ChoiceBox) -> UpdateState {
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
        return .updateAvailable(.init(appcastItem: item, reply: { choice in
            MainActor.assumeIsolated { box.choice = choice }
        }))
    }

    /// Pumps the cooperative pool until `condition` holds (reactions run as main-actor tasks).
    private func waitUntil(_ what: String,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() {
            await Task.yield()
        }
        #expect(condition(), "timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func errorCode(for state: UpdateState) -> Int? {
        guard case .error(let failure) = state else { return nil }
        return (failure.error as NSError).code
    }

    // MARK: - Replays

    /// Sparkle's dismissal callback is deliberately identity-free, so the authoritative cycle-end
    /// signal must terminate an aborted manual check instead of leaving its spinner permanently
    /// visible. The surfaced error remains actionable and starts a genuinely new check on retry.
    @Test func finishedManualCycleCannotLeaveCheckingStateStale() {
        let harness = Harness()

        harness.controller.checkForUpdates()
        #expect(harness.updater.checkForUpdatesCallCount == 1)
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.driver.dismissUpdateInstallation()
        guard case .checking = harness.model.state else {
            Issue.record("identity-free dismissal unexpectedly mutated the active manual check")
            return
        }

        harness.finishSparkleCycle()
        guard case .error(let failure) = harness.model.state else {
            Issue.record("finished manual cycle left stale state: \(harness.model.state)")
            return
        }
        #expect((failure.error as NSError).code == UpdateStateModel.foregroundCycleEndedCode)

        failure.retry()
        #expect(harness.updater.checkForUpdatesCallCount == 2)
    }

    /// The same terminal reconciliation applies after an update prompt was shown: once Sparkle
    /// says that manual session is over, cmux must not leave an action backed by the dead session.
    @Test func finishedManualCycleCannotLeaveUpdatePromptStale() {
        let harness = Harness()
        let prompt = ChoiceBox()

        harness.controller.checkForUpdates()
        harness.model.setState(updateAvailable("0.64.16", replyingInto: prompt))
        harness.controller.driver.dismissUpdateInstallation()
        guard case .updateAvailable = harness.model.state else {
            Issue.record("identity-free dismissal unexpectedly mutated the active prompt")
            return
        }

        harness.finishSparkleCycle()
        #expect(errorCode(for: harness.model.state) == UpdateStateModel.foregroundCycleEndedCode)
        #expect(prompt.choice == nil)
    }

    /// A failed updater start is already an actionable terminal. Check orchestration must not
    /// replace it with preparation/readiness state, and Retry must preserve the original intent.
    @Test func updaterStartupFailureStopsCheckAndRetryResumesIntent() {
        let harness = Harness()
        let startupError = NSError(domain: "test.updater.start", code: 41)
        harness.updater.startError = startupError

        harness.controller.checkForUpdates()

        #expect(harness.updater.checkForUpdatesCallCount == 0)
        guard case .error(let failure) = harness.model.state else {
            Issue.record("startup failure was overwritten by \(harness.model.state)")
            return
        }
        #expect((failure.error as NSError).domain == startupError.domain)

        harness.updater.startError = nil
        failure.retry()
        #expect(harness.updater.checkForUpdatesCallCount == 1)
        #expect(harness.updater.sessionInProgress)
    }

    /// End-to-end accepted-install lifecycle: retire the old prompt, wait for Sparkle's cycle-end
    /// signal, re-resolve the newest nightly, retain visible ownership through the install reply,
    /// and end only when Sparkle starts downloading.
    @Test func dismissedPromptCycleThenFreshInstallReachesDownload() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()
        let freshPrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()

        // The controller dismisses the stale prompt but waits for the authoritative cycle end.
        #expect(harness.updater.checkForUpdatesCallCount == 0)
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }
        #expect(stalePrompt.choice == .dismiss)

        // The identity-free dismiss callback cannot mutate the new session.
        harness.controller.driver.dismissUpdateInstallation()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))

        // Install ownership remains visible until Sparkle actually starts downloading.
        await waitUntil("install confirm") { freshPrompt.choice == .install }
        #expect(harness.model.state == .startingDownload)
        #expect(harness.controller.attemptCoordinator.isMonitoring)
        harness.controller.driver.dismissUpdateInstallation()
        #expect(harness.model.state == .startingDownload)
        harness.controller.driver.showDownloadInitiated(cancellation: {})
        await waitUntil("download ownership") { !harness.controller.attemptCoordinator.isMonitoring }
        guard case .downloading = harness.model.state else {
            Issue.record("download callback did not advance startingDownload; state=\(harness.model.state)")
            return
        }
    }

    /// Acceptance contract: the gap size is irrelevant. A client several releases behind must
    /// dismiss its captured prompt and install the one full artifact returned by the fresh check,
    /// without first installing an intermediate version.
    @Test func severalVersionsBehindInstallsFreshLatestWithoutIntermediateUpdate() async {
        let harness = Harness()
        let capturedPrompt = ChoiceBox()
        let latestPrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.60.0", replyingInto: capturedPrompt))
        harness.controller.attemptUpdate()
        #expect(capturedPrompt.choice == .dismiss)

        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))

        await waitUntil("latest prompt to be installed") { latestPrompt.choice == .install }
        #expect(capturedPrompt.choice != .install)
        #expect(harness.model.state == .startingDownload)
    }

    /// Retry belongs to the operation that failed. An accepted install that hits a Sparkle error
    /// must retry as install-latest and auto-confirm the new prompt, not fall back to a manual
    /// check that requires a second Install click.
    @Test func sparkleErrorRetryPreservesInstallLatestIntent() async {
        let harness = Harness()
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "download failed"]
        )

        harness.controller.attemptUpdate()
        #expect(harness.updater.checkForUpdatesCallCount == 1)
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.driver.showUpdaterError(error, acknowledgement: {})
        harness.finishSparkleCycle(error: error)

        guard case .error(let failure) = harness.model.state else {
            Issue.record("Sparkle error was not visible")
            return
        }
        failure.retry()

        await waitUntil("retry to start another check") {
            harness.updater.checkForUpdatesCallCount == 2
        }
        let latestPrompt = ChoiceBox()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))

        await waitUntil("retry to preserve install intent") { latestPrompt.choice == .install }
    }

    /// A queued install-latest request outranks the manual check it is waiting to replace. If the
    /// old check errors, Retry must consume that queued request and resume it as one install flow.
    @Test func queuedInstallIntentSurvivesActiveManualCheckError() async {
        let harness = Harness()
        let error = NSError(
            domain: SUSparkleErrorDomain,
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "download failed"]
        )

        harness.controller.checkForUpdates()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.attemptUpdate()
        #expect(harness.controller.pendingCheckIntent == .installLatest)

        harness.controller.driver.showUpdaterError(error, acknowledgement: {})
        #expect(harness.controller.pendingCheckIntent == nil)
        harness.finishSparkleCycle(error: error)

        guard case .error(let failure) = harness.model.state else {
            Issue.record("Sparkle error was not visible")
            return
        }
        failure.retry()

        await waitUntil("install retry to start a fresh check") {
            harness.updater.checkForUpdatesCallCount == 2
        }
        let latestPrompt = ChoiceBox()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))

        await waitUntil("queued install retry to confirm latest") { latestPrompt.choice == .install }
    }

    /// Retry on an indeterminate no-update result belongs to Update cmux, even though the result
    /// itself ends the active attempt coordinator before the user presses Retry.
    @Test func unknownNoUpdateRetryPreservesInstallLatestIntent() async {
        let harness = Harness()
        var acknowledgementCount = 0

        harness.controller.attemptUpdate()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.driver.showUpdateNotFoundWithError(
            NSError(domain: SUSparkleErrorDomain, code: 1001),
            acknowledgement: { acknowledgementCount += 1 }
        )
        await harness.clock.fireDeadlineWhenReady()
        await waitUntil("unknown no-update result") {
            if case .notFound(let result) = harness.model.state, case .unknown = result.reason {
                return true
            }
            return false
        }

        harness.controller.retryNoUpdate()
        #expect(acknowledgementCount == 1)
        harness.finishSparkleCycle()
        await waitUntil("install-latest retry to start") {
            harness.updater.checkForUpdatesCallCount == 2
        }

        let latestPrompt = ChoiceBox()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))
        await waitUntil("install-latest retry to confirm") { latestPrompt.choice == .install }
    }

    /// A manual check remains manual when its indeterminate result is retried; finding an update
    /// presents the prompt instead of silently converting Check for Updates into an install.
    @Test func unknownNoUpdateRetryPreservesManualIntent() async {
        let harness = Harness()

        harness.controller.checkForUpdates()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.driver.showUpdateNotFoundWithError(
            NSError(domain: SUSparkleErrorDomain, code: 1001),
            acknowledgement: {}
        )
        await harness.clock.fireDeadlineWhenReady()
        await waitUntil("unknown no-update result") {
            if case .notFound(let result) = harness.model.state, case .unknown = result.reason {
                return true
            }
            return false
        }

        harness.controller.retryNoUpdate()
        harness.finishSparkleCycle()
        await waitUntil("manual retry to start") {
            harness.updater.checkForUpdatesCallCount == 2
        }

        let latestPrompt = ChoiceBox()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))
        await Task.yield()
        #expect(latestPrompt.choice == nil)
    }

    /// Sparkle can finish resolving while the minimum checking display is still visible. If a
    /// second update request supersedes that check, its hidden terminal must be acknowledged so
    /// Sparkle can finish the old cycle and start the queued latest-version check.
    @Test func deferredNoUpdateIsAcknowledgedWhenReplacementRequestSupersedesIt() async {
        let harness = Harness()
        var acknowledgementCount = 0

        harness.controller.checkForUpdates()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.controller.driver.showUpdateNotFoundWithError(
            NSError(domain: SUSparkleErrorDomain, code: 1001),
            acknowledgement: { acknowledgementCount += 1 }
        )
        await harness.clock.waitForDeadlineToArm()

        harness.controller.attemptUpdate()

        #expect(acknowledgementCount == 1)
        guard case .preparingCheck = harness.model.state else {
            Issue.record("replacement request should remain visible while the old cycle finishes")
            return
        }

        harness.finishSparkleCycle()
        await waitUntil("replacement latest-version check to start") {
            harness.updater.checkForUpdatesCallCount == 2
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(acknowledgementCount == 1)
    }

    /// An old up-to-date timer must not acknowledge a newer unknown result, whose Retry action is
    /// the only truthful next step when Sparkle did not report a reason.
    @Test func staleAutoDismissCannotHideActionableNoUpdateReplacement() {
        let harness = Harness()
        var oldAcknowledgementCount = 0
        var newAcknowledgementCount = 0
        let oldResult = UpdateState.NotFound(reason: .upToDate) {
            oldAcknowledgementCount += 1
        }
        let newResult = UpdateState.NotFound(reason: .unknown) {
            newAcknowledgementCount += 1
        }

        harness.model.setState(.notFound(oldResult))
        harness.model.setState(.notFound(newResult))
        harness.controller.acknowledgeNoUpdate(ifMatching: oldResult.id)

        guard case .notFound(let visible) = harness.model.state else {
            Issue.record("stale auto-dismiss hid the actionable replacement")
            return
        }
        #expect(visible.id == newResult.id)
        #expect(oldAcknowledgementCount == 0)
        #expect(newAcknowledgementCount == 0)
    }

    /// Regression for #8368: dismissing the old prompt does not synchronously end Sparkle's
    /// update cycle. Starting the replacement check before Sparkle reports that the old cycle
    /// finished is documented to refocus/no-op, which silently strands the accepted install.
    @Test func installWaitsForDismissedSparkleCycleBeforeStartingFreshCheck() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()

        #expect(stalePrompt.choice == .dismiss)

        // No Sparkle cycle-finished signal has arrived, so starting a new check is not safe yet.
        #expect(harness.updater.checkForUpdatesCallCount == 0)
        #expect(harness.model.showsPill)
    }

    /// Transitions queued before the Install click belong to the prompt-producing check, not the
    /// fresh re-check started by Install. They must be discarded at the attempt boundary so stale
    /// `.checking` / `.updateAvailable` snapshots cannot satisfy and then end the new coordinator
    /// before the real fresh check resolves.
    @Test func attemptUpdateDiscardsQueuedPromptTransitionsAtBoundary() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()
        let freshPrompt = ChoiceBox()

        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        #expect(stalePrompt.choice == .dismiss)
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        for _ in 0..<20 {
            await Task.yield()
        }

        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))

        await waitUntil("fresh prompt to be confirmed") { freshPrompt.choice == .install }
        #expect(harness.controller.attemptCoordinator.isMonitoring)
    }

    /// When Sparkle is not ready yet, the readiness placeholder must not look like the fresh check
    /// start to the install coordinator. The attempt should stay alive until the real check resolves.
    @Test func installAttemptSurvivesUpdaterReadinessWait() async {
        let harness = Harness()
        let freshPrompt = ChoiceBox()

        harness.updater.canCheckForUpdates = false
        harness.controller.attemptUpdate()
        #expect(harness.updater.checkForUpdatesCallCount == 0)
        #expect(harness.controller.attemptCoordinator.isMonitoring)

        harness.updater.canCheckForUpdates = true
        await waitUntil("ready check to run") { harness.updater.checkForUpdatesCallCount == 1 }
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))

        await waitUntil("fresh prompt to be confirmed") { freshPrompt.choice == .install }
        #expect(harness.controller.attemptCoordinator.isMonitoring)
    }

    /// If Sparkle never becomes ready during an install attempt, the readiness timeout is the
    /// accurate user-facing failure. It must end the attempt and disarm the watchdog so the later
    /// 25s install-stall deadline cannot replace it with "Update Didn't Start".
    @Test func installAttemptReadinessTimeoutSurfacesNotReadyAndDisarmsWatchdog() async throws {
        let harness = Harness()

        harness.updater.canCheckForUpdates = false
        harness.controller.attemptUpdate()

        #expect(harness.updater.checkForUpdatesCallCount == 0)
        #expect(harness.controller.attemptCoordinator.isMonitoring)
        #expect(harness.controller.installWatchdog.isArmed)
        guard case .preparingCheck = harness.model.state else {
            Issue.record("install readiness wait should stay visible")
            return
        }

        await waitUntil("not-ready error") {
            errorCode(for: harness.model.state) == UpdateStateModel.updaterNotReadyCode
        }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
        #expect(!harness.controller.installWatchdog.isArmed)

        await harness.clock.fireDeadlines()
        #expect(errorCode(for: harness.model.state) == UpdateStateModel.updaterNotReadyCode)

        guard case .error(let failure) = harness.model.state else {
            Issue.record("readiness timeout should surface an error")
            return
        }
        harness.updater.canCheckForUpdates = true
        failure.retry()

        await waitUntil("retry to start a fresh install check") {
            harness.updater.checkForUpdatesCallCount == 1
        }
        #expect(harness.controller.attemptCoordinator.isMonitoring)
        #expect(harness.controller.installWatchdog.isArmed)
    }

    /// A plain manual check still uses the checking placeholder while it waits for Sparkle
    /// readiness, and still surfaces the same not-ready error if readiness never arrives.
    @Test func manualCheckReadinessTimeoutStillSurfacesNotReady() async {
        let harness = Harness()

        harness.updater.canCheckForUpdates = false
        harness.controller.checkForUpdates()

        guard case .preparingCheck = harness.model.state else {
            Issue.record("manual readiness wait should show preparingCheck, got \(harness.model.state)")
            return
        }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)

        await waitUntil("manual not-ready error") {
            errorCode(for: harness.model.state) == UpdateStateModel.updaterNotReadyCode
        }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
        #expect(!harness.controller.installWatchdog.isArmed)
    }

    /// Readiness can change during the final bounded suspension. The controller must observe that
    /// edge before publishing a false timeout.
    @Test func readinessOnFinalRetryStartsPendingCheck() async {
        let harness = Harness()
        // One read before entering the wait, then twenty loop reads, then the final boundary read.
        harness.updater.scriptedCanCheckForUpdates = Array(repeating: false, count: 21) + [true]

        harness.controller.checkForUpdates()

        await waitUntil("final readiness read to start the check") {
            harness.updater.checkForUpdatesCallCount == 1
        }
        #expect(harness.updater.sessionInProgress)
        if case .error = harness.model.state {
            Issue.record("final readiness edge incorrectly surfaced an error")
        }
    }

    /// If Sparkle accepts the fresh check call but emits no user-driver callback, the watchdog must
    /// turn the stall into a visible error and kill the attempt so a later unrelated resolution is
    /// not auto-installed.
    @Test func watchdogSurfacesErrorWhenFreshCheckNeverRestarts() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        // Sparkle accepted the new check call but never emitted any user-driver callback.
        await harness.clock.fireDeadlineWhenReady()

        await waitUntil("watchdog error") {
            if case .error(let failure) = harness.model.state {
                return (failure.error as NSError).code == UpdateStateModel.installDidNotStartCode
            }
            return false
        }
        // The attempt is dead: a later unrelated resolution must not auto-install.
        let laterPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.17", replyingInto: laterPrompt))
        await waitUntil("later prompt to be processed") {
            if case .updateAvailable = harness.model.state { return true }
            return false
        }
        #expect(laterPrompt.choice == nil)
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
    }

    /// A slow authoritative feed response must never be turned into "Update Didn't Start."
    /// Once Sparkle reports `.checking`, the transport deadline ends; the freshly resolved latest
    /// item remains installable even after that old deadline would have elapsed.
    @Test func slowFreshCheckStillInstallsItsLatestResultAfterWatchdogDeadline() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        await waitUntil("check deadline to end") { !harness.controller.installWatchdog.isArmed }
        await harness.clock.fireDeadlines()
        guard case .checking = harness.model.state else {
            Issue.record("slow check was replaced by \(harness.model.state)")
            return
        }

        let latestPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.20", replyingInto: latestPrompt))
        await waitUntil("latest prompt to be installed") { latestPrompt.choice == .install }
        #expect(harness.controller.installWatchdog.isArmed)
    }

    /// If the old Sparkle cycle never finishes, the preparation phase stays visible until the
    /// watchdog surfaces an error rather than leaving the user at a silently empty pill.
    @Test func watchdogSurfacesErrorWhenRecheckIsDropped() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        #expect(harness.updater.checkForUpdatesCallCount == 0)

        // The old cycle never finishes; the visible preparation phase eventually becomes error.
        await harness.clock.fireDeadlineWhenReady()

        await waitUntil("watchdog error") {
            if case .error(let failure) = harness.model.state {
                return (failure.error as NSError).code == UpdateStateModel.installDidNotStartCode
            }
            return false
        }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
    }

    /// Regression for #8368: an unattributed idle transition can be a stale/background Sparkle
    /// callback, not a user cancellation. If it removes the freshly resolved prompt before the
    /// confirm hand-off, the accepted install must remain visible or become a retryable error.
    @Test func unattributedPromptLossCannotSilentlyEndAcceptedInstall() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        // Dismiss callback, fresh check restart, resolution, and an unattributed stale idle land
        // back-to-back: by the time the confirm hand-off runs, the prompt is gone.
        harness.model.setState(.checking(.init(cancel: {})))
        let freshPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))
        harness.model.setState(.idle)

        await waitUntil("prompt-loss error") {
            errorCode(for: harness.model.state) == UpdateStateModel.installDidNotStartCode
        }
        #expect(freshPrompt.choice == nil)
    }

    /// A fresh install check can legitimately find nothing when this app already matches the
    /// latest release. Preserve Sparkle's visible "up to date" terminal instead of replacing it
    /// with an install failure.
    @Test func acceptedInstallFindingNothingShowsUpToDate() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()
        var didAcknowledgeNotFound = false

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(.notFound(.init(acknowledgement: {
            didAcknowledgeNotFound = true
        })))

        await waitUntil("accepted install to finish") {
            !harness.controller.attemptCoordinator.isMonitoring
        }
        guard case .notFound = harness.model.state else {
            Issue.record("fresh check result was replaced by \(harness.model.state)")
            return
        }
        #expect(!didAcknowledgeNotFound)
        #expect(!harness.controller.installWatchdog.isArmed)
    }

    @Test func actionableNoUpdateAcknowledgementClearsStateExactlyOnce() {
        let harness = Harness()
        var acknowledgementCount = 0
        harness.model.setState(.notFound(.init(reason: .unknown, acknowledgement: {
            acknowledgementCount += 1
        })))

        harness.controller.acknowledgeNoUpdate()
        #expect(harness.model.state.isIdle)
        #expect(acknowledgementCount == 1)

        harness.controller.acknowledgeNoUpdate()
        #expect(acknowledgementCount == 1)
    }

    /// Regression: Retry from "Update Didn't Start" must not recreate the same error when the
    /// installed app already matches the latest version in the feed.
    @Test func retryWhenAlreadyCurrentShowsUpToDateInsteadOfRepeatingInstallError() async {
        let harness = Harness()
        var didAcknowledgeNotFound = false

        harness.controller.setInstallDidNotStartError(diagnostic: "test setup")
        guard case .error(let failure) = harness.model.state else {
            Issue.record("failed to create retryable install error")
            return
        }

        failure.retry()
        #expect(harness.updater.checkForUpdatesCallCount == 1)
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(.notFound(.init(acknowledgement: {
            didAcknowledgeNotFound = true
        })))
        harness.finishSparkleCycle()

        await waitUntil("retry to finish") {
            !harness.controller.attemptCoordinator.isMonitoring
        }
        guard case .notFound = harness.model.state else {
            Issue.record("retry recreated install error: \(harness.model.state)")
            return
        }
        #expect(!didAcknowledgeNotFound)
        #expect(!harness.controller.installWatchdog.isArmed)
    }

    /// If the live prompt is still visible but already answered before the queued confirm
    /// hand-off runs, the controller must not log a fake install attempt or leave the watchdog
    /// armed for a prompt Sparkle will never accept again.
    @Test func answeredPromptSkipsHandOffAndDisarms() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        harness.model.setState(.checking(.init(cancel: {})))
        let freshPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))
        if case .updateAvailable(let available) = harness.model.state {
            available.reply(.skip)
        }

        await waitUntil("watchdog to disarm") { !harness.controller.installWatchdog.isArmed }
        #expect(freshPrompt.choice == .skip)
        await harness.clock.fireDeadlines()
        guard case .updateAvailable(let available) = harness.model.state else {
            Issue.record("answered prompt should stay visible until Sparkle dismisses it")
            return
        }
        #expect(available.reply.isConsumed)
    }

    /// The user cancelling the attempt's fresh check ends the attempt: the watchdog disarms, so
    /// releasing its deadline later must NOT surface a spurious "Update Didn't Start" error over
    /// whatever the user does next.
    @Test func cancellingFreshCheckDisarmsWatchdog() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        harness.finishSparkleCycle()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }
        #expect(harness.controller.installWatchdog.isArmed)

        // The real cancellation closure notifies the lifecycle owner before returning to idle.
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
        guard case .checking(let checking) = harness.model.state else {
            Issue.record("driver did not surface checking")
            return
        }
        checking.cancel()

        await waitUntil("watchdog to disarm") { !harness.controller.installWatchdog.isArmed }
        await harness.clock.fireDeadlines()

        // A subsequent unrelated check sits at "Update Available" with no error and no install.
        let laterPrompt = ChoiceBox()
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: laterPrompt))
        await waitUntil("later prompt to settle") {
            if case .updateAvailable = harness.model.state { return true }
            return false
        }
        #expect(laterPrompt.choice == nil)
    }
}

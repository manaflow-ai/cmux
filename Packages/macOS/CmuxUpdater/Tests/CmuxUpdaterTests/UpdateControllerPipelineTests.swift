import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Deterministic end-to-end replays of the update reaction pipeline: a real ``UpdateController``
/// (reaction task, ``AttemptUpdateCoordinator``, ``InstallWatchdog``, prompt dismissal) driven
/// through a fake ``UpdaterHandle`` and a deadline-controlled clock, with Sparkle's emissions
/// replayed onto the model exactly as the production `cmux-update.log` recorded them.
///
/// The real Sparkle install path only runs in release-channel builds (DEV builds suppress the
/// appcast), so this harness is the only pre-merge way to reproduce pipeline bugs like the
/// NIGHTLY double-idle install loop (https://github.com/manaflow-ai/cmux/pull/7174).
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

    // MARK: - Replays

    /// The production bug, replayed end to end from the user's `cmux-update.log`: Install is
    /// pressed while "Update Available" shows, the stale prompt is dismissed (idle #1), Sparkle's
    /// dismiss callback answers (idle #2), the fresh check restarts and resolves the newer
    /// nightly. The shipped nightly aborted on idle #2 and never sent any reply; the fixed
    /// pipeline must dismiss the stale prompt and install the freshly resolved one.
    @Test func productionDoubleIdleSequenceReachesInstall() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()
        let freshPrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()

        // The controller dismisses the stale prompt and starts exactly one fresh check.
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }
        #expect(stalePrompt.choice == .dismiss)

        // Sparkle's dismissUpdateInstallation answers the dismissal (idle #2 — the emission that
        // used to abort the install), then the fresh check runs and resolves the newer nightly.
        // Emitted back-to-back deliberately: the drain-ordered reactions must observe each one.
        harness.model.setState(.idle)
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))

        // The freshly resolved update is confirmed — the reply the shipped nightly never sent.
        await waitUntil("install confirm") { freshPrompt.choice == .install }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
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
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        for _ in 0..<20 {
            await Task.yield()
        }

        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))

        await waitUntil("fresh prompt to be confirmed") { freshPrompt.choice == .install }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
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
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
    }

    /// If the fresh check never restarts (no `.checking` ever arrives), the watchdog must turn
    /// the silent stall into a visible "Update Didn't Start" error, resolve the re-emitted stale
    /// prompt with a proper dismiss reply, and kill the attempt so a later unrelated resolution
    /// is not auto-installed.
    @Test func watchdogSurfacesErrorWhenFreshCheckNeverRestarts() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        // Sparkle answers the dismissal, re-emits the stale prompt… and then nothing.
        harness.model.setState(.idle)
        let reEmittedPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.15", replyingInto: reEmittedPrompt))
        await waitUntil("prompt to be observed") { harness.controller.attemptCoordinator.isMonitoring }

        await harness.clock.fireDeadlines()

        await waitUntil("watchdog error") {
            if case .error(let failure) = harness.model.state {
                return (failure.error as NSError).code == UpdateStateModel.installDidNotStartCode
            }
            return false
        }
        // The pending Sparkle prompt was resolved, not dropped.
        #expect(reEmittedPrompt.choice == .dismiss)

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

    /// If the delayed re-check is dropped outright — the stale prompt is dismissed (idle) and
    /// then nothing ever emits, not even `.checking` — the watchdog must still surface the
    /// visible error rather than leaving the user at a silently empty pill.
    @Test func watchdogSurfacesErrorWhenRecheckIsDropped() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        // Sparkle answers the dismissal… and then nothing at all: the flow sits at idle.
        harness.model.setState(.idle)
        await harness.clock.fireDeadlines()

        await waitUntil("watchdog error") {
            if case .error(let failure) = harness.model.state {
                return (failure.error as NSError).code == UpdateStateModel.installDidNotStartCode
            }
            return false
        }
        #expect(!harness.controller.attemptCoordinator.isMonitoring)
    }

    /// If the resolved prompt vanishes before the confirm hand-off runs (the user dismissed it
    /// mid-drain, so the live state has moved past the drained snapshot), the controller must
    /// not reply to the already-answered snapshot, and must disarm the watchdog so the leftover
    /// deadline can't fire a spurious error afterwards.
    @Test func vanishedPromptSkipsHandOffAndDisarms() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        // Dismiss callback, fresh check restarts, resolution and the user's dismissal land
        // back-to-back: by the time the confirm hand-off runs, the prompt is gone.
        harness.model.setState(.idle)
        harness.model.setState(.checking(.init(cancel: {})))
        let freshPrompt = ChoiceBox()
        harness.model.setState(updateAvailable("0.64.16", replyingInto: freshPrompt))
        harness.model.setState(.idle)

        await waitUntil("watchdog to disarm") { !harness.controller.installWatchdog.isArmed }
        #expect(freshPrompt.choice == nil)
        await harness.clock.fireDeadlines()
        #expect(harness.model.state.isIdle)
    }

    /// If the live prompt is still visible but already answered before the queued confirm
    /// hand-off runs, the controller must not log a fake install attempt or leave the watchdog
    /// armed for a prompt Sparkle will never accept again.
    @Test func answeredPromptSkipsHandOffAndDisarms() async {
        let harness = Harness()
        let stalePrompt = ChoiceBox()

        harness.model.setState(updateAvailable("0.64.15", replyingInto: stalePrompt))
        harness.controller.attemptUpdate()
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }

        harness.model.setState(.idle)
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
        await waitUntil("fresh check to start") { harness.updater.checkForUpdatesCallCount == 1 }
        #expect(harness.controller.installWatchdog.isArmed)

        // Dismiss callback, fresh check starts, user hits Cancel in the checking popover.
        harness.model.setState(.idle)
        harness.model.setState(.checking(.init(cancel: {})))
        harness.model.setState(.idle)

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

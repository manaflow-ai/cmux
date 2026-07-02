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
    // MARK: - Harness

    @MainActor
    private final class FakeUpdater: UpdaterHandle {
        private(set) var checkForUpdatesCallCount = 0
        var canCheckForUpdates = true
        // False so the controller skips the background launch probe in tests.
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false
        var updateCheckInterval: TimeInterval = 3600
        func start() throws {}
        func checkForUpdates() { checkForUpdatesCallCount += 1 }
        func checkForUpdateInformation() {}
    }

    /// Immediate for the sub-second plumbing delays (the 100ms Sparkle-teardown recheck, the
    /// 250ms readiness retry); parks second-or-longer deadlines (the install watchdog) until the
    /// test releases them with ``fireDeadlines()``, so watchdog time is explicit and no test
    /// ever waits on a wall clock.
    private actor TestDeadlineClock: UpdateClock {
        private var parked: [UUID: CheckedContinuation<Void, any Error>] = [:]

        func sleep(for duration: Duration) async throws {
            try Task.checkCancellation()
            guard duration >= .seconds(1) else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    parked[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelParked(id) }
            }
        }

        func fireDeadlines() {
            let waiters = parked
            parked = [:]
            for continuation in waiters.values {
                continuation.resume()
            }
        }

        private func cancelParked(_ id: UUID) {
            parked.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    /// Captures the `reply` sent to one "Update Available" prompt.
    private final class ChoiceBox: @unchecked Sendable {
        var choice: SPUUserUpdateChoice?
    }

    @MainActor
    private struct Harness {
        let updater: FakeUpdater
        let clock: TestDeadlineClock
        let controller: UpdateController
        var model: UpdateStateModel { controller.model }

        init() {
            let suiteName = "cmux.updater.pipeline-tests"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let updater = FakeUpdater()
            let clock = TestDeadlineClock()
            self.updater = updater
            self.clock = clock
            self.controller = UpdateController(
                log: NoopUpdateLog(),
                clock: clock,
                defaults: defaults,
                isDevLikeBundle: false,
                updaterFactory: { _, _ in updater }
            )
        }
    }

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

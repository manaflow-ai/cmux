import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// The at-most-once prompt reply and the stale-dismissal guard it enables.
///
/// Sparkle's dismiss callback for a stale session can land after a fresh check has already
/// resolved a new prompt; without the consumption bit the driver clobbered the live, unanswered
/// prompt back to idle and the queued install hand-off silently no-oped (the same idle-ambiguity
/// family as the NIGHTLY double-idle loop).
@MainActor
@Suite struct PromptReplyTests {
    private func makeItem(_ version: String) -> SUAppcastItem {
        SUAppcastItem(dictionary: [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": version,
                "sparkle:shortVersionString": version,
            ],
        ]) ?? SUAppcastItem.empty()
    }

    /// The reply forwards the first choice only; the consumption bit flips exactly then.
    @Test func replySendsAtMostOnce() {
        let received = PromptReplyChoiceBox()
        let reply = UpdatePromptReply { choice in
            MainActor.assumeIsolated {
                received.append(choice)
            }
        }
        #expect(!reply.isConsumed)

        reply(.install)
        #expect(reply.isConsumed)
        reply(.dismiss)
        reply(.skip)

        #expect(received.choices == [.install])
    }
    /// A stale session's dismissal must not clobber a live prompt nobody has answered yet —
    /// exactly the late `dismissUpdateInstallation` that would otherwise cancel the freshly
    /// resolved update out from under the attempt coordinator.
    @Test func staleDismissalDoesNotClobberUnansweredPrompt() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let oldReply = UpdatePromptReply { _ in }
        let freshReply = UpdatePromptReply { _ in }

        driver.recordPromptDismissCallbackExpected(for: oldReply)
        model.setState(.updateAvailable(.init(appcastItem: makeItem("0.64.16"), reply: freshReply)))
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("unanswered prompt was clobbered to \(model.state)")
            return
        }
    }

    /// An untracked Sparkle dismissal is the active UI teardown signal and must still clear a
    /// visible prompt instead of stranding it.
    @Test func unexpectedDismissalClearsUnansweredPrompt() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        model.setState(.updateAvailable(.init(appcastItem: makeItem("0.64.16"), reply: { _ in })))
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    /// A stale dismissal arriving after the fresh prompt was confirmed must not reset active
    /// progress to idle; later progress callbacks depend on the model staying in progress.
    @Test func staleDismissalDoesNotClobberInstallProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let oldReply = UpdatePromptReply { _ in }

        driver.recordPromptDismissCallbackExpected(for: oldReply)
        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 10)))
        driver.dismissUpdateInstallation()

        guard case .downloading(let download) = model.state else {
            Issue.record("download progress was clobbered to \(model.state)")
            return
        }
        #expect(download.progress == 10)
    }

    /// A stale dismissal can also land after the fresh prompt was auto-confirmed but before Sparkle
    /// reports download progress. That must not tear down the live install hand-off.
    @Test func staleDismissalDoesNotClobberInstallConfirmedPrompt() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let oldReply = UpdatePromptReply { _ in }
        let freshReply = UpdatePromptReply { _ in }
        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: freshReply)

        driver.recordPromptDismissCallbackExpected(for: oldReply)
        model.setState(.updateAvailable(available))
        available.reply(.install)
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("install-confirmed prompt was clobbered to \(model.state)")
            return
        }
    }

    /// A normal Sparkle progress teardown still clears the model; only a known superseded prompt
    /// dismissal may be ignored while progress is visible.
    @Test func activeProgressDismissalClearsState() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        model.setState(.extracting(.init(progress: 0.5)))
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    /// The current prompt's own dismissal is not stale and should still clear the prompt.
    @Test func expectedDismissalForCurrentPromptClearsState() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let reply = UpdatePromptReply { _ in }
        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: reply)

        driver.recordPromptDismissCallbackExpected(for: reply)
        model.setState(.updateAvailable(available))
        available.reply(.dismiss)
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    /// If the current prompt's dismiss callback arrives before an older prompt's pending stale
    /// callback, clearing the current prompt must not spend the old prompt's marker.
    @Test func currentPromptDismissalDoesNotConsumeOlderStaleMarker() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let oldReply = UpdatePromptReply { _ in }
        let currentReply = UpdatePromptReply { _ in }
        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: currentReply)

        driver.recordPromptDismissCallbackExpected(for: oldReply)
        driver.recordPromptDismissCallbackExpected(for: currentReply)
        model.setState(.updateAvailable(available))
        available.reply(.dismiss)
        driver.dismissUpdateInstallation()
        #expect(model.state.isIdle)

        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 10)))
        driver.dismissUpdateInstallation()

        guard case .downloading(let download) = model.state else {
            Issue.record("old stale dismissal clobbered progress to \(model.state)")
            return
        }
        #expect(download.progress == 10)
    }

    /// If a superseded prompt's Sparkle dismissal arrives while an error is visible, it is drained
    /// there; it must not make a later real progress dismissal look stale.
    @Test func promptDismissIgnoredByErrorDoesNotLeakToNextProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let oldReply = UpdatePromptReply { _ in }
        driver.recordPromptDismissCallbackExpected(for: oldReply)
        model.setState(.error(.init(
            error: NSError(domain: UpdateStateModel.updateErrorDomain, code: UpdateStateModel.installDidNotStartCode),
            retry: {},
            dismiss: {}
        )))

        driver.dismissUpdateInstallation()
        guard case .error = model.state else {
            Issue.record("error was unexpectedly dismissed")
            return
        }

        model.setState(.extracting(.init(progress: 0.5)))
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    /// A real user download cancel still clears progress immediately; the stale dismissal guard
    /// only prevents old Sparkle sessions from clearing a still-active progress state.
    @Test func downloadCancelClearsProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        var cancelled = false

        driver.showDownloadInitiated {
            cancelled = true
        }
        model.state.cancel()

        #expect(cancelled)
        #expect(model.state.isIdle)
    }

    /// Once the prompt is answered, its own dismissal passes through and clears the state.
    @Test func answeredPromptDismissalClearsState() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: { _ in })
        model.setState(.updateAvailable(available))
        available.reply(.install)
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    @Test func readyToInstallWaitsForHostRelaunchPreparation() async {
        let driver = UpdateDriver(
            model: UpdateStateModel(),
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let events = RelaunchPreparationEventQueue()
        let delegate = SuspendedRelaunchPreparationDelegate(events: events)
        let received = PromptReplyChoiceBox()
        driver.actionDelegate = delegate

        driver.showReady { choice in
            MainActor.assumeIsolated {
                received.append(choice)
                events.send(.installReplied)
            }
        }
        guard await events.next() == .preparationBegan else {
            Issue.record("Sparkle received install permission before host relaunch preparation began")
            return
        }
        #expect(received.choices.isEmpty)

        delegate.finishPreparation()
        #expect(await events.next() == .installReplied)
        #expect(received.choices == [.install])
    }

    @Test func retryingFailedTerminationWaitsForFreshHostPreparation() async {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let events = RelaunchPreparationEventQueue()
        let delegate = SuspendedRelaunchPreparationDelegate(events: events)
        driver.actionDelegate = delegate

        driver.showReady { _ in
            MainActor.assumeIsolated { events.send(.installReplied) }
        }
        #expect(await events.next() == .preparationBegan)
        delegate.finishPreparation()
        #expect(await events.next() == .installReplied)

        driver.showInstallingUpdate(withApplicationTerminated: false) {
            MainActor.assumeIsolated { events.send(.terminationRetryInvoked) }
        }
        guard case .installing(let installing) = model.state else {
            Issue.record("failed termination did not expose retry controls")
            return
        }
        #expect(delegate.relaunchInvalidationCount == 0)

        installing.retryTerminatingApplication()
        guard await events.next() == .preparationBegan else {
            Issue.record("Sparkle retry ran before a fresh host preparation")
            return
        }
        #expect(delegate.relaunchInvalidationCount == 1)
        delegate.finishPreparation()
        #expect(await events.next() == .terminationRetryInvoked)
    }

    @Test func dismissingFailedTerminationInvalidatesHostPreparation() async {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let events = RelaunchPreparationEventQueue()
        let delegate = SuspendedRelaunchPreparationDelegate(events: events)
        driver.actionDelegate = delegate

        driver.showReady { _ in
            MainActor.assumeIsolated { events.send(.installReplied) }
        }
        #expect(await events.next() == .preparationBegan)
        delegate.finishPreparation()
        #expect(await events.next() == .installReplied)

        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        guard case .installing(let installing) = model.state else {
            Issue.record("failed termination did not expose dismiss controls")
            return
        }
        #expect(delegate.relaunchInvalidationCount == 0)
        installing.dismiss()

        #expect(delegate.relaunchInvalidationCount == 1)
        #expect(model.state.isIdle)
    }
}

@MainActor
private final class SuspendedRelaunchPreparationDelegate: UpdateActionDelegate {
    private let events: RelaunchPreparationEventQueue
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private(set) var relaunchInvalidationCount = 0

    init(events: RelaunchPreparationEventQueue) {
        self.events = events
    }

    func updaterRequestsRetryCheckForUpdates() {}

    func updaterPreparesToRelaunchApplication() async {
        events.send(.preparationBegan)
        await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func updaterAbandonsRelaunchPreparation() {
        relaunchInvalidationCount += 1
    }

    func updaterWillRelaunchApplication() {}

    func finishPreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }
}

@MainActor
private final class RelaunchPreparationEventQueue {
    enum Event: Equatable {
        case preparationBegan
        case installReplied
        case terminationRetryInvoked
    }

    private var bufferedEvents: [Event] = []
    private var waiter: CheckedContinuation<Event, Never>?

    func send(_ event: Event) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            bufferedEvents.append(event)
        }
    }

    func next() async -> Event {
        if !bufferedEvents.isEmpty {
            return bufferedEvents.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }
}

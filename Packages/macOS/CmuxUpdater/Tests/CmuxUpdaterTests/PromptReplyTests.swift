import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// The at-most-once prompt reply and causal dismissal boundaries.
///
/// Sparkle's identity-free dismiss callback can land after a newer prompt or download owns the
/// UI. Prompt replies record their source at the causal boundary; the later unscoped callback is
/// diagnostic-only and cannot mutate current state.
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
    /// An old session's unscoped dismissal must not clobber a live prompt nobody has answered —
    /// exactly the late `dismissUpdateInstallation` that would otherwise cancel the freshly
    /// resolved update out from under the attempt coordinator.
    @Test func unscopedDismissalDoesNotClobberUnansweredPrompt() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let freshReply = UpdatePromptReply { _ in }

        model.setState(.updateAvailable(.init(appcastItem: makeItem("0.64.16"), reply: freshReply)))
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("unanswered prompt was clobbered to \(model.state)")
            return
        }
    }

    /// Regression for #8368: an untracked Sparkle dismissal has no causal link to the currently
    /// visible prompt. It must not silently clear an unanswered install opportunity.
    @Test func unexpectedDismissalKeepsUnansweredPromptVisible() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        model.setState(.updateAvailable(.init(appcastItem: makeItem("0.64.16"), reply: { _ in })))
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("unanswered prompt was silently dismissed to \(model.state)")
            return
        }
    }

    /// An unscoped dismissal arriving after the fresh prompt was confirmed must not reset active
    /// progress to idle; later progress callbacks depend on the model staying in progress.
    @Test func unscopedDismissalDoesNotClobberInstallProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        model.setState(.downloading(.init(cancel: {}, expectedLength: 100, progress: 10)))
        driver.dismissUpdateInstallation()

        guard case .downloading(let download) = model.state else {
            Issue.record("download progress was clobbered to \(model.state)")
            return
        }
        #expect(download.progress == 10)
    }

    /// An unscoped dismissal can also land after the fresh prompt was answered but before Sparkle
    /// reports download progress. That must not tear down the live install hand-off.
    @Test func unscopedDismissalDoesNotClobberAnsweredPrompt() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let freshReply = UpdatePromptReply { _ in }
        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: freshReply)

        model.setState(.updateAvailable(available))
        available.reply(.install)
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("install-confirmed prompt was clobbered to \(model.state)")
            return
        }
    }

    /// Sparkle's identity-free dismissal cannot terminate progress; causal progress callbacks own
    /// their own cancellation and completion transitions.
    @Test func unscopedDismissalPreservesActiveProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        model.setState(.extracting(.init(progress: 0.5)))
        driver.dismissUpdateInstallation()

        guard case .extracting = model.state else {
            Issue.record("unscoped dismissal cleared active progress")
            return
        }
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

        reply.onConsumed = { [weak driver] reply, choice, source in
            driver?.handlePromptReply(reply, choice: choice, source: source)
        }
        model.setState(.updateAvailable(available))
        available.reply(.dismiss)
        #expect(model.state.isIdle)
        driver.dismissUpdateInstallation()

        #expect(model.state.isIdle)
    }

    /// A delayed action from a prompt that no longer owns the model cannot cancel the lifecycle
    /// associated with the current prompt.
    @Test func stalePromptReplyDoesNotNotifyLifecycleOwner() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let eventSpy = PromptReplyEventSpy()
        driver.eventDelegate = eventSpy
        let staleReply = UpdatePromptReply { _ in }
        staleReply.onConsumed = { [weak driver] reply, choice, source in
            driver?.handlePromptReply(reply, choice: choice, source: source)
        }
        let currentReply = UpdatePromptReply { _ in }
        model.setState(.updateAvailable(.init(
            appcastItem: makeItem("0.64.16"),
            reply: currentReply
        )))

        staleReply(.dismiss)

        #expect(eventSpy.promptDismissalCount == 0)
        guard case .updateAvailable(let available) = model.state else {
            Issue.record("stale prompt reply cleared the current lifecycle")
            return
        }
        #expect(available.reply.id == currentReply.id)
    }

    /// A causal user dismissal clears its own prompt but cannot authorize a later identity-free
    /// dismissal to clear unrelated progress.
    @Test func userPromptDismissalDoesNotAuthorizeLaterUnscopedDismissal() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
        let currentReply = UpdatePromptReply { _ in }
        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: currentReply)

        currentReply.onConsumed = { [weak driver] reply, choice, source in
            driver?.handlePromptReply(reply, choice: choice, source: source)
        }
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

    /// Identity-free dismissal callbacks cannot mutate either a visible error or later progress.
    @Test func unscopedDismissalPreservesErrorAndLaterProgress() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )
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

        guard case .extracting = model.state else {
            Issue.record("unscoped dismissal cleared later progress")
            return
        }
    }

    /// A real user download cancel still clears progress immediately at its causal callback.
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

    /// Regression for #8368: after the user accepts an install, a Sparkle dismissal arriving
    /// before `showDownloadInitiated` must not hide the only visible evidence of that attempt.
    @Test func acceptedInstallDismissalKeepsAttemptVisible() {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let available = UpdateState.UpdateAvailable(appcastItem: makeItem("0.64.16"), reply: { _ in })
        model.setState(.updateAvailable(available))
        model.setState(.startingDownload)
        available.reply.consume(.install, source: .installAttempt)
        driver.dismissUpdateInstallation()

        #expect(model.showsPill)
        #expect(model.state == .startingDownload)
    }
}

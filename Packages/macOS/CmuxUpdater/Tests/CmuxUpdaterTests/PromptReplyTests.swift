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
        let received = Box()
        let reply = UpdateState.PromptReply { choice in
            received.append(choice)
        }
        #expect(!reply.isConsumed)

        reply(.install)
        #expect(reply.isConsumed)
        reply(.dismiss)
        reply(.skip)

        #expect(received.choices == [.install])
    }

    private final class Box: @unchecked Sendable {
        private(set) var choices: [SPUUserUpdateChoice] = []
        func append(_ choice: SPUUserUpdateChoice) { choices.append(choice) }
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

        model.setState(.updateAvailable(.init(appcastItem: makeItem("0.64.16"), reply: { _ in })))
        driver.dismissUpdateInstallation()

        guard case .updateAvailable = model.state else {
            Issue.record("unanswered prompt was clobbered to \(model.state)")
            return
        }
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
}

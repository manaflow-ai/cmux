import Foundation

extension PageWebView {
    /// True while this exact allowlist is installing or installed. A false result after an
    /// asynchronous install failure lets the native owner retry its cached binding on its next
    /// question refresh; navigation and visibility invalidation also return false.
    public func hasQuestionKeyTargets(_ targets: [PageQuestionKeyTarget]) -> Bool {
        guard descriptor.isAgentPage, !isClosed, let channel = chromiumSession?.questionKeys else { return false }
        return channel.hasTargets(targets)
    }

    /// Binds the agent pane's native pending question to Return in its Other field. Each key's
    /// proof is single-use; an incomplete answer leaves the next genuine key available. The page
    /// must label its fieldset with `data-cmux-question-session` and `data-cmux-question-id`.
    /// Those public labels never carry the isolated channel's nonce.
    ///
    /// The card's `data-cmux-question-enter-reply` is its exact `{optionId,answers,annotations?}`
    /// JSON. The owner validates that immutable snapshot, redeems it below, then rechecks its
    /// pending decision nonce/person-instance and spends its native person-key witness. Generic
    /// user-input uptime and later page callbacks never qualify.
    /// Returns false on any other page or engine, or before Chromium is attached.
    @discardableResult
    public func bindQuestionKeyTarget(_ target: PageQuestionKeyTarget?, received: @escaping (PageQuestionKeySnapshot) -> Void) -> Bool {
        bindQuestionKeyTargets(target.map { [$0] } ?? [], received: received)
    }

    /// The complete native allowlist. The actual key's original card selects its approved target;
    /// neither dictionary order nor a page request chooses a question. An unchanged collection is
    /// idempotent; a changed collection revokes unused snapshots before replacing its binding.
    @discardableResult
    public func bindQuestionKeyTargets(_ targets: [PageQuestionKeyTarget], received: @escaping (PageQuestionKeySnapshot) -> Void) -> Bool {
        guard descriptor.isAgentPage, let chromiumSession, !isClosed else { return false }
        guard !targets.isEmpty, targets.allSatisfy(\.isValid) else {
            chromiumSession.questionKeys?.invalidate()
            return targets.isEmpty
        }
        guard let channel = chromiumSession.questionKeys, channel.documentGuardPrepared else { return false }
        channel.bind(targets, received: received)
        return true
    }

    /// Consumes one private snapshot and checks its original DOM references, focus, labels and
    /// reply in the issuing isolated context. No new target lookup or page-world request runs.
    /// The native caller must recheck its own pending state and person-key witness after awaiting.
    public func redeemQuestionKeySnapshot(_ snapshot: PageQuestionKeySnapshot) async -> Bool {
        guard descriptor.isAgentPage, let channel = chromiumSession?.questionKeys, !isClosed else { return false }
        return await channel.redeem(snapshot)
    }
}

import Foundation

/// The single owner of the one in-flight `surface.resume.set` approval prompt
/// (issue #9369).
///
/// The legacy flow ran `NSAlert.runModal()` synchronously inside the socket
/// main-actor hop, so while the approval alert was open every unrelated
/// main-lane request — including `surface.resume.get` and `.clear` — queued
/// behind it until the socket timeout. The prompt now presents asynchronously;
/// while it is open this coordinator tracks the pending set so:
/// - the initiating (and any duplicate) set answers a retryable
///   `approvalPending` result instead of blocking,
/// - the user's decision applies the binding when it arrives and is handed to
///   the next retried set for the same request,
/// - `surface.resume.clear` can cancel the prompt outright.
@MainActor
final class SurfaceResumeApprovalPromptCoordinator {
    /// The user's answer to the approval prompt.
    struct Decision: Equatable, Sendable {
        let policy: SurfaceResumeApprovalPolicy
        let commandPrefix: [String]?
    }

    /// The identity of one requested approval: the same surface proposing the
    /// same command in the same folder is the same logical set request.
    struct RequestKey: Equatable, Sendable {
        let surfaceID: UUID
        let command: String
        let cwd: String?

        init(surfaceID: UUID, binding: SurfaceResumeBindingSnapshot) {
            self.surfaceID = surfaceID
            command = binding.command
            cwd = binding.cwd
        }
    }

    /// Presents the prompt without blocking the main actor, reports the user's
    /// decision (or `nil` when cancelled) exactly once, and returns the closure
    /// that dismisses the prompt programmatically.
    typealias Presenter = @MainActor (
        _ completion: @escaping @MainActor (Decision?) -> Void
    ) -> @MainActor () -> Void

    enum BeginOutcome: Equatable {
        /// A prompt is open (this request's, or another one keeping the single
        /// prompt slot busy); the set should answer `approvalPending` so the
        /// caller retries.
        case pending
        /// A finished prompt for this request left a decision; the retried set
        /// consumes it and completes synchronously without prompting again.
        case decided(Decision)
    }

    private final class PendingPrompt {
        let key: RequestKey
        let onDecision: @MainActor (Decision) -> Void
        var cancel: @MainActor () -> Void = {}

        init(key: RequestKey, onDecision: @escaping @MainActor (Decision) -> Void) {
            self.key = key
            self.onDecision = onDecision
        }
    }

    private var pendingPrompt: PendingPrompt?
    private var completedDecision: (key: RequestKey, decision: Decision)?

    /// Consumes a completed decision for `key`, joins the already-open prompt,
    /// or opens a new one. `onDecision` runs when the user answers, so the set
    /// completes (approval record + binding) even if the caller never retries.
    func begin(
        key: RequestKey,
        presenter: Presenter,
        onDecision: @escaping @MainActor (Decision) -> Void
    ) -> BeginOutcome {
        if let completed = takeCompletedDecision(key: key) {
            return .decided(completed)
        }
        guard pendingPrompt == nil else { return .pending }
        let prompt = PendingPrompt(key: key, onDecision: onDecision)
        pendingPrompt = prompt
        prompt.cancel = presenter { [weak self] decision in
            self?.finish(prompt: prompt, decision: decision)
        }
        // A synchronous presenter (tests) may have decided before returning.
        if let completed = takeCompletedDecision(key: key) {
            return .decided(completed)
        }
        return .pending
    }

    /// Whether a prompt is currently open for `surfaceID`.
    func hasPendingPrompt(surfaceID: UUID) -> Bool {
        pendingPrompt?.key.surfaceID == surfaceID
    }

    /// Dismisses the open prompt for `surfaceID` (if any) without a decision
    /// and drops any unconsumed decision for it, so `surface.resume.clear`
    /// wins over the in-flight approval.
    func cancelPending(surfaceID: UUID) {
        if completedDecision?.key.surfaceID == surfaceID {
            completedDecision = nil
        }
        guard let prompt = pendingPrompt, prompt.key.surfaceID == surfaceID else { return }
        pendingPrompt = nil
        prompt.cancel()
    }

    private func takeCompletedDecision(key: RequestKey) -> Decision? {
        guard let completed = completedDecision, completed.key == key else { return nil }
        completedDecision = nil
        return completed.decision
    }

    private func finish(prompt: PendingPrompt, decision: Decision?) {
        // A cancelled prompt (or a stale sheet callback after cancelPending
        // already released the slot) must not apply anything.
        guard pendingPrompt === prompt else { return }
        pendingPrompt = nil
        guard let decision else { return }
        completedDecision = (prompt.key, decision)
        prompt.onDecision(decision)
    }
}

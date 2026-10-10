// Destructive and person-only actions (`isDestructive`, `isPersonOnly`). One gate in
// `perform` covers every entrypoint: keyboard, menu, palette, and context
// menus ask the App's confirmation presenter; the control socket and the
// CLI (capturing callers) must pass `confirm: true` or get a typed refusal.
extension ActionRegistry {
    /// Asks the user to confirm `id` (a sheet in the App). Calls `proceed` with the invocation
    /// carrying the effect it showed (the run acts only on it, cx-zk9t); not calling it cancels.
    /// The presenter may call `proceed` without asking when nothing is at stake (closing a
    /// workspace whose terminals are all idle).
    public typealias ConfirmationPresenter = @MainActor (ActionID, ActionInvocation, _ proceed: @escaping @MainActor (_ pinned: ActionInvocation?) -> Void) -> Void

    /// The refusal a scripted run of a destructive action gets without
    /// `confirm: true`. Stable text: the socket and CLI report it.
    public static func confirmationRequiredReason(for id: ActionID) -> String {
        confirmationRequiredReason(forRawID: id.rawValue)
    }

    /// `confirmationRequiredReason(for:)` for callers off the main actor.
    public nonisolated static func confirmationRequiredReason(forRawID id: String) -> String {
        "\(id) is destructive; pass confirm:true (CLI: --confirm) to run it"
    }

    /// Whether `invocation` of `id` must be confirmed first: a destructive or person-only action (cx-zk9t).
    public func needsConfirmation(_ id: ActionID, _ invocation: ActionInvocation) -> Bool {
        descriptor(for: id).map { $0.isPersonOnly ? !invocation.isPersonConfirmed : $0.isDestructive && !invocation.isConfirmed } ?? false
    }

    /// Runs the gate for an unconfirmed destructive invocation. Returns
    /// whether the request was handled (asked, or refused).
    func gateDestructive(_ id: ActionID, _ invocation: ActionInvocation) -> Bool {
        let canonical = canonicalID(for: id)
        if isCapturingRefusal {
            refuse(Self.confirmationRequiredReason(for: canonical))
            return false
        }
        guard let confirmationPresenter else {
            refuse(Self.confirmationRequiredReason(for: canonical))
            return false
        }
        confirmationPresenter(canonical, invocation) { [weak self] pinned in
            self?.perform(canonical, invocation: (pinned ?? invocation).personConfirmed())
        }
        return true
    }
}

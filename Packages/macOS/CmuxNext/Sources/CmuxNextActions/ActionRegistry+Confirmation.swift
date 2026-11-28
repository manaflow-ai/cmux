// Destructive actions (`ActionDescriptor.isDestructive`). One gate in
// `perform` covers every entrypoint: keyboard, menu, palette, and context
// menus ask the App's confirmation presenter; the control socket and the
// CLI (capturing callers) must pass `confirm: true` or get a typed refusal.
extension ActionRegistry {
    /// Asks the user to confirm `id` (a sheet in the App). Calls `proceed`
    /// to run the action confirmed; not calling it cancels. The presenter
    /// may call `proceed` without asking when nothing is at stake (closing
    /// a workspace whose terminals are all idle).
    public typealias ConfirmationPresenter = @MainActor (ActionID, ActionInvocation, _ proceed: @escaping @MainActor () -> Void) -> Void

    /// The refusal a scripted run of a destructive action gets without
    /// `confirm: true`. Stable text: the socket and CLI report it.
    public static func confirmationRequiredReason(for id: ActionID) -> String {
        confirmationRequiredReason(forRawID: id.rawValue)
    }

    /// `confirmationRequiredReason(for:)` for callers off the main actor.
    public nonisolated static func confirmationRequiredReason(forRawID id: String) -> String {
        "\(id) is destructive; pass confirm:true (CLI: --confirm) to run it"
    }

    /// Whether `invocation` of `id` must be confirmed before it runs.
    public func needsConfirmation(_ id: ActionID, _ invocation: ActionInvocation) -> Bool {
        descriptor(for: id)?.isDestructive == true && !invocation.isConfirmed
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
        confirmationPresenter(canonical, invocation) { [weak self] in
            self?.perform(canonical, invocation: invocation.confirmed())
        }
        return true
    }
}

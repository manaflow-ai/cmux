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
    ///
    /// The presenter runs inside an `action.gate` interval (`gated`), not the action's own: most
    /// presenters confirm in a later turn (a `Task`, a daemon round trip, a sheet), and the
    /// confirmed run is timed by itself with the age of the press carried in the invocation.
    /// `settle` puts a preview of another action back first.
    func gateDestructive(_ id: ActionID, _ invocation: ActionInvocation, settle: () -> Void) -> Bool {
        let canonical = canonicalID(for: id)
        if isCapturingRefusal {
            refuse(Self.confirmationRequiredReason(for: canonical))
            return false
        }
        guard let confirmationPresenter else {
            refuse(Self.confirmationRequiredReason(for: canonical))
            return false
        }
        gated(id, invocation) { stamped in
            settle()
            confirmationPresenter(canonical, stamped) { [weak self] in
                self?.perform(canonical, invocation: stamped.confirmed())
            }
        }
        return true
    }
}

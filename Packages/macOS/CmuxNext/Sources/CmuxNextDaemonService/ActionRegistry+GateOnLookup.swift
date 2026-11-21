public import CmuxNextActions

extension ActionRegistry {
    /// Offers the bound actions `ids` only where `find`, the runs' own lookup of what they act on,
    /// finds it (Leo 2026-11-17: "just... stop showijg the toggle on gui"). Wherever `find` throws an
    /// ``ActionFailure`` the row leaves that target's context menu and the palette, and every run is
    /// refused with the failure's message, so the CLI and MCP still hear why
    /// (``ActionTargetVisibility/gate(_:in:reason:)``). One lookup decides both, so a row's state and
    /// its run agree. A not-found failure (an explicit target that names nothing) and any other error
    /// stay the run's answer. `find` must change nothing: the palette asks it on every open.
    @MainActor public func gate(_ ids: [ActionID], unlessFinds find: @escaping @MainActor (ActionInvocation) throws -> Void) {
        for id in ids {
            ActionTargetVisibility.gate(id, in: self) { invocation in
                do {
                    try find(invocation)
                    return nil
                } catch let failure as ActionFailure {
                    return failure.isNotFound ? nil : failure.message
                } catch {
                    return nil
                }
            }
        }
    }
}

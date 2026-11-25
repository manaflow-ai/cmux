// The machine's one rule on top of `cmux-focus-core`'s reply; split from FocusMachine.swift (over the 400-line cap).
extension FocusMachine {
    /// The focus started or stopped waiting for another tab (``FocusState/awaitsOtherTab``: a creation's new tab the
    /// window does not show yet): the responder applies again in this reduction, so the page the person left gives up
    /// the keys in the key's turn, and takes them back when the wait ends without landing (P0 INVERSE-KEY). The rule
    /// reads only the state the machine returned; `cmux-focus-core` itself emits no effect for a wait.
    static func reapplyingOnWaitChange(_ result: Reduction, waited: Bool, state: FocusState) -> Reduction {
        let moves = result.effects.contains { if case .moveResponder = $0 { true } else { false } }
        guard waited != state.awaitsOtherTab, !moves else { return result }
        var reapplied = result
        reapplied.changed = true
        reapplied.effects.append(.moveResponder(state.resolved))
        return reapplied
    }
}

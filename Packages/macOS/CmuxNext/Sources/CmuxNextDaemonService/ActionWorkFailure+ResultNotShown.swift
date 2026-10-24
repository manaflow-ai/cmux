public import CmuxNextActions

extension ActionWorkFailure {
    /// A command that went through whose result the store cannot show (``AppliedThroughReply`` not held): the
    /// control socket answers `unavailable` with ``RefusalStrings/resultNotShown``, and the command may have
    /// applied, so a caller must not simply retry it.
    public static var resultNotShown: ActionWorkFailure {
        var failure = ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.resultNotShown)
        failure.mayHaveApplied = true
        return failure
    }
}

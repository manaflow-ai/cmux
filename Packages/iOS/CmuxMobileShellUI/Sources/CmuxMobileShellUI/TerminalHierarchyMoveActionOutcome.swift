import CmuxMobileShell

enum TerminalHierarchyMoveActionOutcome {
    case unavailable
    case completed(Result<Void, MobileWorkspaceMutationFailure>)
}

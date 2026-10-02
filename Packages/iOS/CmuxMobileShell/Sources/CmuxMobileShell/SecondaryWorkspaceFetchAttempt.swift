import CmuxMobileShellModel

enum SecondaryWorkspaceFetchAttempt {
    case received([MobileWorkspacePreview])
    case transientFailure
    case permanentFailure
}

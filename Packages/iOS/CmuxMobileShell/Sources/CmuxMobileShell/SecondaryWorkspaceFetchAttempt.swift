enum SecondaryWorkspaceFetchAttempt {
    case received(SecondaryWorkspaceSnapshot)
    case transientFailure
    case permanentFailure
}

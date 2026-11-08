enum SecondaryOwnedEventSubscriptionActivation {
    case active
    case transientFailure
    case permanentFailure
    /// Registry ownership changed while activation or catch-up was suspended.
    case superseded
}

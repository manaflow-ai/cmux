enum SecondaryEventSubscriptionActivation {
    case transientFailure
    case permanentFailure
    /// `requiresCatchUp` is true when the host installed a missing
    /// registration and events emitted before the acknowledgement were lost.
    case active(requiresCatchUp: Bool)
}

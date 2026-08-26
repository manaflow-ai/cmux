enum MobileSecondaryStatusAuthority: Equatable, Sendable {
    case accepted
    /// Stack-authenticated status can temporarily omit all host identity when
    /// verification capacity or the best-effort status token is unavailable.
    case identityUnavailable
    case rejected
}

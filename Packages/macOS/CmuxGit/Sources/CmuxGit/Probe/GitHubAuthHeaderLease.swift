/// A credential header paired with the cache generation that authorized it.
///
/// The generation is intentionally opaque to callers: two equal header values
/// resolved at different times are still different leases, so delayed network
/// responses cannot mutate newer authentication state.
struct GitHubAuthHeaderLease: Sendable, Equatable {
    let value: String
    let generation: UInt64
}

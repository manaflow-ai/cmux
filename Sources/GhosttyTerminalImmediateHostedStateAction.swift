/// What a `GhosttyTerminalView` update may do to the hosted view's immediate
/// visible/active state.
enum GhosttyTerminalImmediateHostedStateAction: Equatable {
    /// The owner with a live binding applies both flags.
    case applyVisibleAndActive

    /// A bound host that lost the lease may still un-show its own surface and
    /// nothing more. Active/focus state stays ownership-gated. An owner's hide
    /// is allowed whether or not it is currently bound: the lease is
    /// authoritative for the surface's state, and that was the apply rule
    /// before this enum existed.
    case hideOnly

    /// A non-owner that is not bound must not touch the hosted view.
    case deferred
}

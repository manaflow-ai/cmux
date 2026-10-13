/// The relay's free-tier state (cmux-coderouter `free_tier::FreeState`), as
/// its `free_state` events name it.
public nonisolated enum FreeTierState: String, Sendable, Hashable, CaseIterable {
    /// The setting is off, or no relay is connected.
    case off
    /// Ready: the lease starts at the next signed-out agent request.
    case idle
    case checking
    case active
    case usedThisMonth = "used_this_month"
    case unsupported
    case notVerified = "not_verified"
    case serviceOff = "service_off"
    case backoff
}

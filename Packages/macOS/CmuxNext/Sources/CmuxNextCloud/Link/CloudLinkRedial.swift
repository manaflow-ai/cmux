public import Observation

/// Whether a Cloud machine's running link redials (cx-z5oif): after sleep,
/// a network drop or a Wi-Fi change the `cmux-tui remote connect` client
/// redials while its local socket stays up, so the daemon connection over
/// that socket still reads as connected. Only the client's snapshots tell.
@MainActor @Observable
public final class CloudLinkRedial {
    public internal(set) var isRedialing = false

    nonisolated init() {}
}

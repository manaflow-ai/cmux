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

/// Whether a Cloud machine's running link's attach answer said the signed-in caller owns the
/// machine (``CloudAttachEndpoint/callerOwnsVM``): set when that link comes up, false once it
/// ends, never saved past it (``CloudMachineLink/callerOwnsVM``).
@MainActor @Observable
public final class CloudLinkOwnership {
    public private(set) var callerOwnsVM = false
    @ObservationIgnored private var link = 0

    nonisolated init() {}

    /// Link `link`'s answer, unless a newer link's already came (the hops can arrive out of order).
    func publish(_ owns: Bool, link: Int) {
        guard link > self.link else { return }
        self.link = link
        callerOwnsVM = owns
    }
}

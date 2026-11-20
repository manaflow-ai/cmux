public import Observation

/// Whether a Cloud machine's running link said the signed-in caller owns the machine: set when
/// that link comes up, false once it ends, never saved past it (``CloudLinkSession``).
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

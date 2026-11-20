public import Observation

/// Whether a machine's last app-link connect failed in a way no new connect changes
/// (``CloudLinkError/endsWaits(_:)``: this Mac's connection helper refused to start), and why, in the
/// link's own words (``CloudLinkError/failureReason(_:)``). A start's or a move's wait ends on ``refused``
/// instead of connecting again until its deadline (a DEV build whose helper had no device key showed
/// "Thinking" for minutes while every connect failed the same way, 2026-11-10).
@MainActor @Observable
public final class CloudLinkRefusal {
    /// The last connect failed for good; false again once a connect starts or a wait begins without one.
    public private(set) var refused = false
    /// Why the last connect failed, until the next connect starts.
    @ObservationIgnored public private(set) var reason: String?

    public init() {}

    /// A connect starts: what the last one said no longer holds.
    public func connecting() {
        refused = false
        reason = nil
    }

    /// The connect failed with `error`.
    public func ended(_ error: any Error) {
        reason = CloudLinkError.failureReason(error)
        refused = CloudLinkError.endsWaits(error)
    }

    /// A wait begins. With no connect in flight (`connecting` false) a refusal is an earlier connect's, so the
    /// wait does not end on it: its first beat connects again, which asks the helper anew. A connect a guard
    /// skipped (a script's, on a machine that is not live) would otherwise leave an old answer to end it at once.
    public func waitBegins(connecting: Bool) {
        if !connecting { refused = false }
    }
}

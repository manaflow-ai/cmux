/// How a message row's status ("Delivered", "Read") comes and goes, as
/// measured on iOS 26 Messages.
public enum ConversationStatusMotion: Equatable, Sendable {
    /// Shown or hidden in place.
    case none
    /// A status landing on the row grows out of its own center.
    case grow
    /// A status landing on a row whose send flight is still in the air
    /// grows in when the flight lands: the row hides its status under the
    /// flight, so it would grow unseen and pop in at full size at the landing.
    case growOnLanding
    /// A status leaving the row shrinks slightly and fades in ~0.1 s.
    case leave

    /// `sameRow`: the cell showed this row before (a fresh or reused cell
    /// shows its status in place). `wasNotDelivered`: the status leaving is
    /// Not Delivered (Try Again moves the row, so it leaves at once).
    /// `isFlying`: the row's send flight is in the air (its status hidden,
    /// so one leaving it goes at once instead of flashing back to fade).
    public static func of(sameRow: Bool, wasShown: Bool, isShown: Bool, wasNotDelivered: Bool, isFlying: Bool) -> ConversationStatusMotion {
        guard sameRow else { return .none }
        if !wasShown, isShown { return isFlying ? .growOnLanding : .grow }
        if wasShown, !isShown, !wasNotDelivered, !isFlying { return .leave }
        return .none
    }
}

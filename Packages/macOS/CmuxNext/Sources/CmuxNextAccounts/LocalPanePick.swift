/// The pane a provider's login or logout runs in. Accounts reads this Mac's
/// sign-ins (its home folder and Keychain), so the command must run on this
/// Mac, never in an SSH or Cloud workspace's pane: there it would sign in or
/// out an unrelated account on that machine. The focused pane wins when it
/// is local, else the first local pane of the window; none: nil.
public struct LocalPanePick<Pane> {
    public let pane: Pane?

    public init(focused: Pane?, others: [Pane], isLocal: (Pane) -> Bool) {
        if let focused, isLocal(focused) {
            pane = focused
        } else {
            pane = others.first(where: isLocal)
        }
    }
}

/// What a Cloud app link does after `cmux link machine update` ran here
/// (`CloudMachineSession.reconnectAfterUpdate`).
public enum CloudLinkAfterUpdate: Equatable, Sendable {
    /// Connect; `dropTicket` first lets it run over the current connect's ticket.
    case connect(dropTicket: Bool)
    /// A connect hop runs (maybe to the old daemon): connect afresh once it ends.
    case connectAfterHop

    /// The daemon may have restarted (`restarted`): a connection the app still holds is to the old
    /// daemon, and its drop may reach the app after the CLI answered (each has its own carrier
    /// connection). Its ticket goes now, so that late drop is an old ticket's and changes nothing,
    /// and a fresh connect runs (after a hop in flight). Nothing restarted: a healthy connection
    /// stays (a connect with a live ticket does nothing); an ended link connects again, and so does
    /// a refused daemon's (no connection): that connect waits for an event, and its next ask of the
    /// socket would only end the link.
    public init(restarted: Bool, linkEnded: Bool, connected: Bool, connecting: Bool) {
        if restarted {
            self = connecting ? .connectAfterHop : .connect(dropTicket: true)
        } else {
            self = .connect(dropTicket: !linkEnded && !connected && !connecting)
        }
    }
}

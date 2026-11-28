import Foundation

/// The echoes of this app's own live divider and column drags
/// (`layout-delta-v1`). A drag sends one command per frame; each commit comes
/// back as a `layout-changed` that names the drag's transaction. While the
/// drag is live the layout already shows the pointer's value, so its echo
/// does no work: the newest one is held, and laid over its screen once when
/// the drag ends (the daemon's last committed value, which an `.ended`
/// command that changes nothing never echoes). Any other layout for that
/// screen, a snapshot or a new connection supersedes it.
struct LayoutEchoes {
    struct Held {
        var transaction: ClientTransactionID
        var layout: ScreenLayoutDelta
        /// The store's snapshot barrier and connection when it was held: a
        /// snapshot or a reconnect since then is newer.
        var barrier: UInt64
        var epoch: Int
    }

    var live: Set<ClientTransactionID> = []
    var heldByScreen: [ScreenID: Held] = [:]
}

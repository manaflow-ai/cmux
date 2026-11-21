import Foundation

/// A new browser workspace shown at the press: the workspace and its one browser tab are a stand-in
/// in the store (`Intent.createWorkspace`) from the turn this is made, so its window shows the
/// workspace and starts its page in the press's frame, and `create-workspace {first_tab}`
/// (`workspace-first-tab-v1`) runs behind it.
///
/// That request takes no transaction: the daemon's raw `tab-added` of the first tab is hidden by a
/// guess (``ProvisionalTab/matched(_:in:)``) until the reply names it. The caller then waits for
/// the store to hold the reply's events (``DaemonStore/applied(through:)``) and calls
/// ``confirmed(surface:at:handOver:)``; a refused or failed create calls ``failed()``.
///
/// ```swift
/// let shown = BrowserWorkspaceStandIn(key: key, name: "web", url: url, engine: "cef", profile: nil, in: store)
/// let reply = try await connection.createWorkspaceWithFirstTabWaitingForReply(name: "web", key: key, firstTab: tab)
/// await store.applied(through: sequence)
/// shown.confirmed(surface: reply.firstTab!.surface, at: sequence) { surface in movePage(shown.tab, surface) }
/// ```
///
/// A test passes a `DaemonStore()` it fills with `apply(snapshot:)` and `apply(batch:)`.
@MainActor
public struct BrowserWorkspaceStandIn {
    /// The stand-in tab's id (`TabModel.id`): the id the app makes the page under.
    public let tab: String
    /// The stand-in tab's surface.
    public let surface: SurfaceID
    /// The create intent's transaction in the store's log.
    public let transaction: ClientTransactionID
    private let store: DaemonStore

    /// Shows the workspace and its page in `store` now, before any await.
    ///
    /// - Parameters:
    ///   - key: The workspace key `create-workspace` sends.
    ///   - name: The workspace's name, shown from the first frame.
    ///   - url: The address the tab opens.
    ///   - engine: Its engine tag (`cef`, `webkit`).
    ///   - profile: Its browser profile id; nil is `default`.
    ///   - index: Its place in the daemon's order; nil is the end.
    ///   - store: The store of the daemon that makes the workspace.
    public init(key: WorkspaceKey, name: String, url: String, engine: String, profile: String?, index: Int? = nil, in store: DaemonStore) {
        let provisional = ProvisionalTab(), transaction = ClientTransactionID.generate()
        tab = provisional.id
        surface = provisional.surface
        self.transaction = transaction
        self.store = store
        let first = provisional.browser(url: url, engine: engine, profile: profile)
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: name, tab: first), index: index), transaction: transaction)
    }

    /// The reply named the daemon's first tab `surface`: it takes the stand-in's place in this turn.
    ///
    /// - Parameters:
    ///   - surface: The daemon's tab.
    ///   - sequence: The daemon's event sequence at the reply; nil settles at the next snapshot.
    ///   - handOver: Moves what the app made for the stand-in (its page) to the daemon's tab. It runs in this turn,
    ///     before any view sees the swap, and not for a stand-in the person closed first.
    /// - Returns: Whether the daemon's tab took the stand-in over; false when the person closed the stand-in first
    ///   (the daemon's tab closes, `CancelledCreation`).
    @discardableResult
    public func confirmed(surface: SurfaceID, at sequence: UInt64?, handOver: (SurfaceID) -> Void) -> Bool {
        let cancelled = store.creations.wasCancelled(transaction)
        ProvisionalTab.created(transaction, surface: surface, in: store)
        let landed = !cancelled && store.tab(surface: surface) != nil
        if landed { handOver(surface) }
        if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
        return landed
    }

    /// The create was refused or failed: the stand-in workspace goes.
    public func failed() {
        store.rejectIntent(transaction)
    }
}

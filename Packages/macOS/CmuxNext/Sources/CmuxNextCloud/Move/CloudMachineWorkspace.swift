public import CmuxNextDaemon

/// The workspace on a Cloud machine where its terminals and chats land (`CloudHandlers.terminalAnchor`:
/// a chat start's chat, `cloud start-session`, a browser tab): the machine's first workspace, or a new
/// one when it has none.
///
/// The app finds a workspace by its id alone (`MachineRegistry.workspace(id:)`: this Mac's tree, then
/// the first machine's that lists it), and machines made from one image list the same key for their
/// first workspace (capture d143d61c: cloud-chats and cloud-chats-3 both listed workspace-1 as
/// a40723c3-…). A chat opened in such a workspace was shown in another machine's: the window showed
/// cloud-chats-2's empty chat, the chat on cloud-chats never loaded its page, and its seeded first
/// message, handed over only at the page's handshake, never went. So a workspace another machine
/// (or this Mac) also lists (`listedElsewhere`) is never the anchor: a new one is made instead.
@MainActor
public struct CloudMachineWorkspace {
    public init() {}

    /// The first workspace `store` lists that no other tree lists, nil when it has none. A daemon's
    /// connection is up before its first tree is applied (right after a resume), and the list then is
    /// the last connection's, not "none": the read waits for this connection's tree (`liveTreeEpoch`),
    /// up to `limit`, so an open never makes a second workspace. The connection is published before
    /// the store hears `.connected` (which moves the epoch), so the store must say connected too. A
    /// tree that never comes within `limit` throws `notConnected`: never "none", which would make one.
    public static func existing(in store: DaemonStore, within limit: Duration = .seconds(10), notConnected: @autoclosure () -> any Error,
                                listedElsewhere: (String) -> Bool = { _ in false }) async throws -> String? {
        let current = { @MainActor @Sendable in
            if case .connected = store.connectionState { return store.liveTreeEpoch == store.connectionEpoch }
            return false
        }
        if !(await current()), await !CloudWait.holds(within: limit, until: current) { throw notConnected() }
        return store.workspaces.lazy.map(\.id).first { !listedElsewhere($0) }
    }

    /// ``existing(in:within:notConnected:listedElsewhere:)``, else a workspace `create` makes (nil:
    /// `notConnected`), after `beforeCreate`, whose throw makes none. `created` says which.
    public static func first(in store: DaemonStore, notConnected: @autoclosure () -> any Error, listedElsewhere: (String) -> Bool = { _ in false },
                             beforeCreate: () throws -> Void, create: () async -> String?) async throws -> (id: String, created: Bool) {
        if let first = try await existing(in: store, notConnected: notConnected(), listedElsewhere: listedElsewhere) { return (first, false) }
        // The live tree, rather than the stale pre-wait tree, decides whether creation needs consent.
        try beforeCreate()
        guard let id = await create() else { throw notConnected() }
        return (id, true)
    }
}

import Foundation

/// Detaches the control clients that earlier streams of this view left attached.
///
/// A reconnect ends the local transport process. When the transport's remote half outlives
/// its client, as a roaming shell does by design, the old `tmux -CC` client stays attached
/// to the view and keeps receiving every pane's output. Each reconnect adds one: a host
/// measured with 74 of them, most days old, had its tmux server at a quarter of a CPU. The
/// view belongs to this install alone, so any other control client attached to it is one of
/// these, and the stream that just connected detaches them.
extension RemoteTmuxViewConnection {
    nonisolated static let clientListFormat = "#{client_name} #{client_control_mode} #{client_session}"

    /// The clients to detach, read from `list-clients -F clientListFormat` rows: control-mode
    /// clients attached to the view, other than this stream's own. Without its own name the
    /// stream cannot tell itself from a leftover, so it detaches nothing.
    nonisolated static func leftoverViewClients(
        rows: [String],
        viewSessionName: String,
        ownClientName: String
    ) -> [String] {
        guard !ownClientName.isEmpty else { return [] }
        return rows.compactMap { row in
            let fields = row.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3,
                  fields[1] == "1",
                  fields[2] == viewSessionName,
                  fields[0] != ownClientName else { return nil }
            return fields[0]
        }
    }

    /// Both queries and every detach belong to the stream that was current when the cleanup
    /// started. A reconnect in between hands the second query to a new client with a new name,
    /// and comparing that list with the old name would detach this install's own new client,
    /// so any change of stream ends the cleanup; the new stream's bringup runs its own.
    func detachLeftoverViewClients(_ conn: RemoteTmuxControlConnection) async {
        let generation = conn.processGeneration
        let sameStream = { [weak self] in
            self?.connection === conn && conn.processGeneration == generation && conn.connectionState == .connected
        }
        guard let own = await reconcileListQuery(conn, "display-message -p '#{client_name}'")?.first,
              sameStream(),
              let rows = await reconcileListQuery(
                conn, "list-clients -F \(RemoteTmuxHost.shellSingleQuoted(Self.clientListFormat))"),
              sameStream()
        else { return }
        let leftovers = Self.leftoverViewClients(
            rows: rows, viewSessionName: view.sessionName, ownClientName: own)
        guard !leftovers.isEmpty else { return }
        conn.record("detach-leftover-view-clients count=\(leftovers.count)")
        for name in leftovers {
            guard sameStream() else { return }
            _ = conn.send("detach-client -t \(RemoteTmuxHost.shellSingleQuoted(name))")
        }
    }
}

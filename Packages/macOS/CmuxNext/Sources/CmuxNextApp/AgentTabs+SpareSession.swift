import CmuxNextDaemon

/// Which tab opening an existing chat adopts the prewarmed New Tab page (``AgentTabStore/view(for:)``,
/// `NewTabSparePool`). The spare is this Mac's page, connected to this Mac's acpmux, and its
/// handshake is past, so it serves only a chat whose open needs nothing that handshake carries:
/// - a chat of this Mac's acpmux: not another machine's (its own host), not a Chief home's
///   (`chief:` tabs, and an older subagent tab of this Mac's host the Chief home keeps);
/// - with a session: a tab with none is a New Tab page or a new chat (the spare's own path);
/// - no New Tab page, no seed (a new chat's folder, draft, prompt or surface);
/// - no kept or relaunch wake state (a composer or shell box its own handshake hands over).
enum SpareSessionAdoption {
    /// The session the tab's page switches the spare to, nil when the tab gets a page of its own.
    static func session(local: Bool, kind: AgentPaneHostKind, session: String?, newTabPage: Bool, seeded: Bool,
                        wake: Bool, chiefKeeps: (String) -> Bool) -> String? {
        guard local, kind == .local, let session, !session.isEmpty, !newTabPage, !seeded, !wake, !chiefKeeps(session)
        else { return nil }
        return session
    }
}

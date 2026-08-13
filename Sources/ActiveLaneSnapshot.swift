import Foundation

/// Remembers which workspaces had a live agent lane, so a reboot does not lose your place.
///
/// `TmuxSessionReaper` recovers sessions whose tmux daemon outlived the app — the
/// force-quit case, where the conversations are literally still running. A *reboot* is
/// the other case: tmux dies with the machine, so at restore time there is nothing left
/// to enumerate. The set of workspaces that mattered has to have been written down while
/// they were still alive. That is what this does.
///
/// The signal is `Workspace.ownedTmuxSession`, which the `*-remote` wrappers register
/// over the socket (`set_tmux_session`) when a lane attaches and clear when it closes.
/// Registration is used in preference to deriving the name from the workspace directory
/// because the wrappers also accept an explicit lane word (`claude-remote -n boards`),
/// which no derivation can predict — see `TmuxSessionReaper.sessionName`.
///
/// Restoring a lane rebuilds its workspace from the template, which re-runs the panel
/// command; the `claude-lane` shim then resolves the transcript to `--resume` from its
/// own ledger, keyed on the workspace UUID cmux injects. So the UUID recorded here is
/// what ties a restored pane back to its conversation.
enum ActiveLaneSnapshot {

    /// One workspace that had a live lane when the snapshot was taken.
    struct Lane: Codable, Equatable {
        let workspace: UUID
        let session: String
        let directory: String
        let title: String
    }

    struct Snapshot: Codable, Equatable {
        let ts: Int
        let lanes: [Lane]
    }

    /// `~/.local/state/cmux/last-active-lanes.json`.
    ///
    /// Deliberately outside the app container, alongside `claude-lane`'s own ledger in
    /// `~/.local/state/claude-lane/`: the two are read together when diagnosing a restore,
    /// and neither should vanish if the app bundle is replaced.
    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("last-active-lanes.json", isDirectory: false)
    }

    // MARK: - Encoding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func encode(_ snapshot: Snapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: - Persistence

    /// Write the snapshot, creating the state directory if needed.
    ///
    /// An empty lane list is still written: "nothing was running" is a real answer, and
    /// leaving a stale file behind would offer to restore lanes the user has since closed.
    @discardableResult
    static func write(_ snapshot: Snapshot, to url: URL = stateURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encode(snapshot).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[LaneSnapshot] write failed: %@", String(describing: error))
            return false
        }
    }

    /// Read the last snapshot, or nil when absent or unreadable.
    static func read(from url: URL = stateURL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decode(data)
        } catch {
            NSLog("[LaneSnapshot] read failed: %@", String(describing: error))
            return nil
        }
    }

    // MARK: - Capture

    /// One workspace considered for the snapshot, reduced to what the policy needs.
    struct Candidate: Equatable {
        let workspace: UUID
        let title: String
        let directory: String
        let instanceIndex: Int
        /// `Workspace.ownedTmuxSession` — whatever the wrapper registered, if anything.
        let registered: String?
    }

    /// The lanes running right now, from the live tmux session list.
    ///
    /// Registration alone is not enough to find them. `cmux set-tmux-session` exists but
    /// nothing calls it today, so `ownedTmuxSession` is nil in practice and a snapshot
    /// built on it is always empty. The reattach path has the same problem and solves it
    /// by *deriving* each workspace's session name and intersecting with the live list —
    /// that is the signal used here, with registration preferred when it is present.
    ///
    /// Carries the caveat `TmuxSessionReaper.sessionName` documents: a lane started with
    /// an explicit word suffix (`claude-remote -n boards`) derives to a different name and
    /// will not be seen until something registers it.
    static func lanes(from candidates: [Candidate], live: Set<String>) -> [Lane] {
        var lanes: [Lane] = []
        var claimed: Set<String> = []
        for candidate in candidates {
            let session: String?
            if let registered = candidate.registered, !registered.isEmpty {
                session = registered
            } else {
                let derived = TmuxSessionReaper.sessionName(
                    directory: candidate.directory,
                    instanceIndex: candidate.instanceIndex
                )
                session = live.contains(derived) ? derived : nil
            }
            // One workspace per session, so two workspaces sharing a directory and
            // instance cannot both record — and later both rebuild onto the same session.
            guard let session, !session.isEmpty, claimed.insert(session).inserted else {
                continue
            }
            lanes.append(
                Lane(
                    workspace: candidate.workspace,
                    session: session,
                    directory: candidate.directory,
                    title: candidate.title
                )
            )
        }
        return lanes
    }

    // MARK: - Selection

    /// The lanes worth offering to restore.
    ///
    /// Pure so the policy is testable without a running app. Two filters:
    ///
    /// - `attached` drops lanes whose workspace already has a lane this launch, which is
    ///   what makes the command idempotent and safe to invoke twice. It also means a
    ///   partial restore can simply be re-run to pick up the remainder.
    /// - `openWorkspaces` drops lanes whose workspace is no longer in the sidebar. The
    ///   workspace set is reconciled against the repo tree, so a directory removed while
    ///   cmux was closed leaves a recorded lane with nowhere to land.
    static func restorable(
        snapshot: Snapshot,
        openWorkspaces: Set<UUID>,
        attached: Set<UUID>
    ) -> [Lane] {
        snapshot.lanes.filter { lane in
            openWorkspaces.contains(lane.workspace) && !attached.contains(lane.workspace)
        }
    }
}

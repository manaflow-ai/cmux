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

    /// A live tmux session and the directory it was started in.
    typealias LiveSession = (session: String, directory: String)

    /// Expand `~` and resolve symlinks, so two spellings of one directory compare equal.
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    }

    /// The lanes running right now, matched to workspaces by directory.
    ///
    /// Three signals, in descending order of trust:
    ///
    /// 1. **Registration.** `claude-remote` calls `cmux set-tmux-session` with the real
    ///    name, so when it is present it is exactly right. It is cleared on every app
    ///    restart, which is why it cannot be the only signal.
    /// 2. **Session directory.** `tmux` reports where each session started, and that maps
    ///    back to a workspace unambiguously. This is the one that carries the load.
    /// 3. **Derived name.** Last resort, for a session whose directory has since moved.
    ///
    /// Deriving cannot be the primary signal: the sidebar instance index need not match
    /// the one in the session name — a workspace at index 56 owns a session called plain
    /// `azdevops` — and an explicit lane word (`claude-remote -n boards`) never appears in
    /// the workspace at all. Both cases resolve correctly by directory.
    static func lanes(from candidates: [Candidate], live: [LiveSession]) -> [Lane] {
        let names = Set(live.map(\.session))
        var byDirectory: [String: [String]] = [:]
        for entry in live {
            byDirectory[canonical(entry.directory), default: []].append(entry.session)
        }

        var lanes: [Lane] = []
        var claimed: Set<String> = []

        func take(_ session: String?) -> String? {
            guard let session, !session.isEmpty, !claimed.contains(session) else { return nil }
            claimed.insert(session)
            return session
        }

        for candidate in candidates {
            var resolved: String?
            if let registered = candidate.registered, names.contains(registered) {
                resolved = take(registered)
            }
            if resolved == nil {
                let directory = canonical(candidate.directory)
                resolved = take(byDirectory[directory]?.first { !claimed.contains($0) })
            }
            if resolved == nil {
                let derived = TmuxSessionReaper.sessionName(
                    directory: candidate.directory,
                    instanceIndex: candidate.instanceIndex
                )
                resolved = take(names.contains(derived) ? derived : nil)
            }
            // One workspace per session: two workspaces on the same directory must not
            // both record, or both would later rebuild onto the same session.
            guard let session = resolved else { continue }
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

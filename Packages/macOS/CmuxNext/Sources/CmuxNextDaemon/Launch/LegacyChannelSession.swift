import CmuxNextCompat
import Foundation

/// One-time adopt of the old shared daemon session by an untagged NIGHTLY,
/// RC or staging build (cx-r650e).
///
/// Before cx-6so.41 (79dbcd0baf025) these builds ran the session `cmux-app`
/// with cmux-tui's default state root (`<Application Support>/cmux-tui/sessions`).
/// Since then each runs `cmux-app-<channel>` with its state in
/// `cmux/tags/<channel>/tui`, and nothing moved the old state, so the first
/// launch after the update opened an empty session: no launch snapshot (the
/// "Connecting to cmux-tui" screen) and none of the person's workspaces,
/// terminals or agents, which stayed with the old `cmux-app` daemon.
///
/// A channel build adopts `cmux-app` and the default root in place, once,
/// when this bundle itself ran the old session (its own defaults name the
/// old session's launch snapshot, `cmuxNext.launchSnapshotPath.cmux-app`, so
/// a release build's live `cmux-app` or another channel's is never taken),
/// that snapshot lists workspaces, and its own session is untouched (never
/// started, or only the launch's own unused New Tab page). Nothing is
/// copied, so nothing can diverge; the decision is recorded beside the
/// channel's own state directory (`legacy-session-adopted` beside it, from BuildIdentity) so every
/// later launch keeps it, also after the own session would no longer count
/// as untouched. A session the person used is never replaced.
struct LegacyChannelSession: Sendable {
    static let session = "cmux-app"
    static let channels = ["nightly", "rc", "staging"]
    static let markerName = "legacy-session-adopted"

    let applicationSupport: URL
    /// Where this bundle's last handshake put the old session's snapshot (its own defaults).
    let rememberedSnapshot: @Sendable () -> String?

    init(applicationSupport: URL,
                rememberedSnapshot: @escaping @Sendable () -> String? = { LaunchSnapshotLocation().path(session: LegacyChannelSession.session) }) {
        self.applicationSupport = applicationSupport
        self.rememberedSnapshot = rememberedSnapshot
    }

    /// One answer per process and build: decided at the first ask (before the
    /// daemon starts), so a snapshot written later never moves a running app.
    private static let decisions = DecisionCache()

    /// The old shared registry root: cmux-tui's default state root on macOS.
    var legacyRoot: URL { applicationSupport.appendingPathComponent("cmux-tui/sessions", isDirectory: true) }

    /// Beside the channel's own state directory (BuildIdentity's `cmux/tags/<channel>/tui`).
    func marker(stateDirectory: URL) -> URL {
        stateDirectory.deletingLastPathComponent().appendingPathComponent(Self.markerName)
    }

    /// The channel of an untagged channel build (`com.cmuxterm.app.<channel>`
    /// running `cmux-app-<channel>`), else nil.
    static func channel(bundleID: String?, session: String) -> String? {
        channels.first { bundleID == "com.cmuxterm.app.\($0)" && session == "cmux-app-\($0)" }
    }

    /// True when the channel build uses the old session: recorded earlier, or
    /// decided now (and recorded). `session` and `stateDirectory` are the
    /// build's own names.
    func adopts(bundleID: String?, session: String, stateDirectory: URL?) -> Bool {
        guard let channel = Self.channel(bundleID: bundleID, session: session), let stateDirectory else { return false }
        return Self.decisions.answer("\(applicationSupport.path)|\(channel)") { decide(channel: channel, session: session, stateDirectory: stateDirectory) }
    }

    private func decide(channel: String, session: String, stateDirectory: URL) -> Bool {
        let marker = marker(stateDirectory: stateDirectory)
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        guard let legacy = rememberedSnapshot(),
              URL(fileURLWithPath: legacy).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == legacyRoot.standardizedFileURL.path,
              Self.workspaces(at: legacy, touchedOnly: false) > 0,
              isUntouched(session: session, in: stateDirectory) else { return false }
        let record = ["session": Self.session, "state_root": legacyRoot.path,
                      "adopted_at": ISO8601DateFormatter().string(from: Date())]
        guard let data = try? CheckedJSON.data(withJSONObject: record, options: [.sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: marker, options: .atomic)
        } catch {
            return false // unrecorded: never adopt for one launch only
        }
        return true
    }

    /// The build's own session never ran (no `<session>-<id>` registry), or
    /// its launch snapshot shows no workspace the person touched. A registry
    /// without a snapshot counts as touched (it cannot be checked).
    func isUntouched(session: String, in stateDirectory: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
        let ours = entries.filter { $0.hasPrefix(session + "-") && !$0.dropFirst(session.count + 1).contains("-") }
        if ours.isEmpty { return true }
        guard let snapshot = LaunchSnapshotLocation.find(session: session, in: stateDirectory) else { return false }
        return Self.workspaces(at: snapshot, touchedOnly: true) == 0
    }

    /// The workspaces of a launch snapshot that are not Home or ephemeral;
    /// with `touchedOnly`, only those the person may have used: one with no
    /// tab listed, or with a terminal, a browser tab, or a chat bound to a
    /// conversation or agent session (the launch's own New Tab page is none). An unreadable file counts
    /// as one touched workspace, so it never leads to an adopt.
    static func workspaces(at path: String, touchedOnly: Bool) -> Int {
        guard let data = FileManager.default.contents(atPath: path), data.count <= LaunchSnapshot.maximumBytes,
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = file["tree"] as? [String: Any], let workspaces = tree["workspaces"] as? [[String: Any]]
        else { return touchedOnly ? 1 : 0 }
        return workspaces.filter { workspace in
            guard workspace["kind"] as? String != "home", workspace["ephemeral"] as? Bool != true else { return false }
            guard touchedOnly else { return true }
            // Only a workspace whose every tab is an unused New Tab page is untouched; one
            // that lists no tab (not settled yet) cannot be checked, so it counts as used.
            let tabs = tabs(of: workspace)
            return tabs.isEmpty || tabs.contains(where: isTouched)
        }.count
    }

    private static func tabs(of workspace: [String: Any]) -> [[String: Any]] {
        let screens = workspace["screens"] as? [[String: Any]] ?? []
        return screens.flatMap { $0["panes"] as? [[String: Any]] ?? [] }.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
    }

    private static func isTouched(_ tab: [String: Any]) -> Bool {
        guard tab["kind"] as? String == "conversation" else { return true }
        let binding = tab["conversation"] as? [String: Any] ?? [:]
        if let conversation = binding["conversation"], !(conversation is NSNull) { return true }
        let session = (binding["agent_session"] as? [String: Any])?["session"]
        return session != nil && !(session is NSNull)
    }
}

// memory: fixed one Bool per Application Support folder and channel (`LegacyChannelSession.channels`, 3).
/// `LegacyChannelSession`'s per-process answers.
final class DecisionCache: Sendable {
    private let answers = Mutex<[String: Bool]>([:])

    func answer(_ key: String, _ decide: () -> Bool) -> Bool {
        answers.withLock { answers in
            if let known = answers[key] { return known }
            let value = decide()
            answers.updateValue(value, forKey: key)
            return value
        }
    }
}

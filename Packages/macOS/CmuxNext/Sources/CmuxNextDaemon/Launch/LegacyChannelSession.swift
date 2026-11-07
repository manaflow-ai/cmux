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

    /// True when the channel build uses the old session: recorded earlier, or decided now and recorded
    /// (cmux-daemon-launch-core `legacy_channel` and `legacy_adopts`, which read and write the disk).
    /// `session` and `stateDirectory` are the build's own names. A library that does not answer adopts nothing.
    func adopts(bundleID: String?, session: String, stateDirectory: URL?) -> Bool {
        struct Request: Encodable {
            var applicationSupport: String, bundleId: String?, session: String, stateDirectory: String?
            var rememberedSnapshot: String?, now: String
        }
        var request = Request(applicationSupport: applicationSupport.path, bundleId: bundleID, session: session,
                              stateDirectory: stateDirectory?.path, rememberedSnapshot: nil, now: "")
        guard stateDirectory != nil,
              let channel = DaemonLaunchRules.call("legacy_channel", request, as: String?.self) ?? nil else { return false }
        return Self.decisions.answer("\(applicationSupport.path)|\(channel)") {
            request.rememberedSnapshot = rememberedSnapshot()
            request.now = ISO8601DateFormatter().string(from: Date())
            return DaemonLaunchRules.call("legacy_adopts", request, as: Bool.self) ?? false
        }
    }
}

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

import Foundation

/// The downloads of one tab that went to a session
/// (``BrowserReplTabOwnership/downloadRoute(startedBy:source:policy:fileRoots:)``),
/// with where each came from.
///
/// A download's bytes are a read of every place its request went, so the
/// decision made when WebKit picked its destination is made again for each
/// redirect WebKit reports after it (``redirect(_:to:policy:fileRoots:)``)
/// and, under the session's policy and directories then, before the session
/// gets the finished file's path (``finish(_:policy:fileRoots:)``). A
/// download either one refuses is no longer the session's.
public struct BrowserReplSessionDownloads: Sendable {
    private var entries: [String: Entry] = [:]

    private struct Entry: Sendable {
        /// The session, and whether it reads the download's URLs as written.
        let recipient: BrowserReplNetworkRecipient
        var source: BrowserReplDownloadSource
        var sessionID: String { recipient.sessionID }

        /// Why its session may not receive the download, in the form that
        /// session may read (``BrowserReplDownloadRefusal/reason(seesCredentials:)``).
        func refusal(policy: (String) -> BrowserReplDomainPolicy?, fileRoots: (String) -> [String]?) -> String? {
            source.refusal(policy: policy(sessionID), fileRoots: fileRoots(sessionID) ?? [])?
                .reason(seesCredentials: recipient.seesCredentials)
        }
    }

    /// How a download that finished goes on.
    public enum Finish: Sendable, Equatable {
        /// It never went to a session, or one refused it before.
        case notSessions
        /// To `sessionID`, which gets its path.
        case session(String)
        /// Not to `sessionID`, whose policy or directories refuse a place it
        /// came from (`reason`).
        case refused(sessionID: String, reason: String)
    }

    public init() {}

    /// Records that download `id`, from `source`, went to `recipient`. A
    /// refusal reaches a recipient that does not see the tab's credentials
    /// without the URLs' credential values.
    public mutating func add(_ id: String, to recipient: BrowserReplNetworkRecipient, source: BrowserReplDownloadSource) {
        entries[id] = Entry(recipient: recipient, source: source)
    }

    /// The session download `id` went to, if it still is that session's.
    public func sessionID(of id: String) -> String? {
        entries[id]?.sessionID
    }

    /// Records that download `id` went on to `url`. When its session may not
    /// read that place, the download is no longer the session's, and the
    /// session and the reason, in the form that session may read, are
    /// returned.
    public mutating func redirect(
        _ id: String,
        to url: String,
        policy: (String) -> BrowserReplDomainPolicy?,
        fileRoots: (String) -> [String]?
    ) -> (sessionID: String, reason: String)? {
        guard var entry = entries[id] else { return nil }
        entry.source.went(to: url)
        entries[id] = entry
        guard let reason = entry.refusal(policy: policy, fileRoots: fileRoots) else {
            return nil
        }
        entries[id] = nil
        return (entry.sessionID, reason)
    }

    /// Forgets download `id` and says whether its session gets its path:
    /// every place it came from is judged again under the session's policy
    /// and directories now.
    public mutating func finish(
        _ id: String,
        policy: (String) -> BrowserReplDomainPolicy?,
        fileRoots: (String) -> [String]?
    ) -> Finish {
        guard let entry = entries.removeValue(forKey: id) else { return .notSessions }
        if let reason = entry.refusal(policy: policy, fileRoots: fileRoots) {
            return .refused(sessionID: entry.sessionID, reason: reason)
        }
        return .session(entry.sessionID)
    }

    /// Forgets download `id` (it failed) and returns its session.
    public mutating func remove(_ id: String) -> String? {
        entries.removeValue(forKey: id)?.sessionID
    }

    /// Forgets the downloads that went to `sessionID`, which is leaving the
    /// tab, and returns their ids. They end with the session: the caller
    /// cancels each and removes its partial file. A session's download never
    /// outlives it, so it never finishes with no session and goes to the
    /// user's download location or save panel instead.
    public mutating func sessionLeft(_ sessionID: String) -> [String] {
        let ids = entries.filter { $0.value.sessionID == sessionID }.map(\.key).sorted()
        for id in ids { entries[id] = nil }
        return ids
    }

    /// Forgets every download (the tab's last session left, or it closed)
    /// and returns their ids, which the caller cancels as ``sessionLeft(_:)``'s.
    public mutating func removeAll() -> [String] {
        let ids = entries.keys.sorted()
        entries.removeAll()
        return ids
    }
}

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
        let sessionID: String
        var source: BrowserReplDownloadSource
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

    /// Records that download `id`, from `source`, went to `sessionID`.
    public mutating func add(_ id: String, sessionID: String, source: BrowserReplDownloadSource) {
        entries[id] = Entry(sessionID: sessionID, source: source)
    }

    /// Records that download `id`, from `source`, went to `recipient`.
    public mutating func add(_ id: String, to recipient: BrowserReplNetworkRecipient, source: BrowserReplDownloadSource) {
        add(id, sessionID: recipient.sessionID, source: source)
    }

    /// The session download `id` went to, if it still is that session's.
    public func sessionID(of id: String) -> String? {
        entries[id]?.sessionID
    }

    /// Records that download `id` went on to `url`. When its session may not
    /// read that place, the download is no longer the session's, and the
    /// session and the reason are returned.
    public mutating func redirect(
        _ id: String,
        to url: String,
        policy: (String) -> BrowserReplDomainPolicy?,
        fileRoots: (String) -> [String]?
    ) -> (sessionID: String, reason: String)? {
        guard var entry = entries[id] else { return nil }
        entry.source.went(to: url)
        entries[id] = entry
        guard let reason = entry.source.refusal(policy: policy(entry.sessionID), fileRoots: fileRoots(entry.sessionID) ?? []) else {
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
        if let reason = entry.source.refusal(policy: policy(entry.sessionID), fileRoots: fileRoots(entry.sessionID) ?? []) {
            return .refused(sessionID: entry.sessionID, reason: reason)
        }
        return .session(entry.sessionID)
    }

    /// Forgets download `id` (it failed) and returns its session.
    public mutating func remove(_ id: String) -> String? {
        entries.removeValue(forKey: id)?.sessionID
    }
}

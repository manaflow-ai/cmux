import Foundation

/// cmux: the Chief subagents this app knows (Lawrence 2026-10-22: "why did u forget to link
/// a459"), so Home links every bare mention of one (`a459`, `**a459**`, `- a459:`, `(a459)`) in
/// any agent's text, whichever Chief wrote it. The Mac Chief links its own replies when it posts
/// them (optchat-chief `link_subagents`), but a Cloud Chief's reply, or one the Mac Chief posted
/// before it knew the session, names the id bare: the app fills this from the Mac Chief home's
/// acpmux lanes (`optchat-sub-<home>-a<n>`), and Home links each id to its chat
/// (`cmux://chief/<home>/session/<session>`). An id not here stays plain text.
///
/// Read from any thread (rendering); a change posts ``didChange`` on the main thread, and the
/// open transcripts render again.
public final class HomeSubagentLinks: @unchecked Sendable {
    public static let shared = HomeSubagentLinks()

    /// Posted on the main thread after the ids or their links changed.
    public static let didChange = Notification.Name("HomeSubagentLinks.didChange")

    private let lock = NSLock()
    private var links: [String: String] = [:]
    private var revision = 0

    public init() {}

    /// No subagents: the scan of text where an id is never a mention (code).
    static let none = HomeSubagentLinks()

    /// Replaces the known subagents: id (`a12`) to its chat link. An entry whose id is not a
    /// subagent id or whose link is not a Chief subagent link (``URL/isChiefSubagentLink``) is
    /// dropped. Returns whether anything changed (then ``didChange`` is posted).
    @discardableResult
    public func set(_ new: [String: String]) -> Bool {
        let kept = new.reduce(into: [String: String]()) { out, entry in
            let id = entry.key.lowercased()
            guard Self.isID(id), let url = URL(string: entry.value), url.isChiefSubagentLink else { return }
            out[id] = entry.value
        }
        let changed: Bool = lock.withLock {
            guard kept != links else { return false }
            links = kept
            revision += 1
            return true
        }
        guard changed else { return false }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
        }
        return true
    }

    /// The chat link of subagent `id` (`a12`), nil when this app knows no such subagent.
    public func link(for id: String) -> String? {
        lock.withLock { links[id.lowercased()] }
    }

    /// Whether any subagent is known (the bare-link scan skips the id pattern otherwise).
    var isEmpty: Bool { lock.withLock { links.isEmpty } }

    /// Bumped on every change: a rendered-line cache made at another revision is stale.
    var currentRevision: Int { lock.withLock { revision } }

    /// A subagent id: `a` and 1 to 6 digits, no leading zero (optchat-chief `is_id`).
    static func isID(_ id: String) -> Bool {
        let digits = id.utf8.dropFirst()
        return id.utf8.first == UInt8(ascii: "a") && (1...6).contains(digits.count)
            && digits.first != UInt8(ascii: "0") && digits.allSatisfy { (48...57).contains($0) }
    }
}

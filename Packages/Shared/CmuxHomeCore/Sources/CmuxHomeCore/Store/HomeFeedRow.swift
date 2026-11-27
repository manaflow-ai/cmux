public import Foundation

/// One Feed notice shown in the main Chief's transcript: a read-only line for the person, never a
/// message to the Chief (it is not in the conversation, so the Chief never reads it).
///
/// User 2026-10-20: "we don't necessarily want to bother the chief with lots of TMI type
/// information, but we want to make it like easily accessible. ... having it possible to unify the
/// views. I mean, you can opt out if you want, but I think having that as your sort of recurring
/// append feed is pretty nice." The app maps its Feed's notices to these rows
/// (``HomeStore/setFeedRows(_:in:)``); Settings > Chief > Show the Feed in Chief turns them off.
public struct HomeFeedRow: Hashable, Sendable {
    /// The newest notices a transcript shows; older ones stay in the Feed.
    public static let limit = 50

    /// The Feed item's id; the row's key derives from it.
    public var id: String
    /// Who posted it ("GitHub", "cmux"), shown before the title.
    public var source: String
    /// The notice's one-line title.
    public var title: String
    /// What a click on the line opens (the pull request, the release notes); nil: the line takes no click.
    public var url: URL?
    /// When the Feed got it; the line sits at that time in the transcript.
    public var date: Date

    public init(id: String, source: String, title: String, url: URL?, date: Date) {
        (self.id, self.source, self.title, self.url, self.date) = (id, source, title, url, date)
    }

    /// Who a Feed row is from in the transcript: the Feed itself, never a participant of the
    /// conversation. A row stamped with the Chief's id took the Chief's name and avatar (user
    /// 2026-11-09: "cmux updated should not be 'sent by chief'"); its ``source`` names the poster.
    public static let author = ParticipantID("cmux.feed")

    /// The line the transcript shows: the source, then the title ("GitHub · PR 12 merged"). A title
    /// that already starts with its source ("cmux updated to nightly 4295228") shows alone, so the
    /// app's own notice does not read "cmux · cmux updated …".
    public var line: String {
        let named = title.range(of: source + " ", options: [.anchored, .caseInsensitive]) != nil
        return source.isEmpty || named ? title : "\(source) · \(title)"
    }

    /// The row's transcript item: a read-only line from the Feed (``author``), not from any participant
    /// (the renderer draws the words).
    func item() -> TranscriptItem {
        var item = TranscriptItem(key: IdempotencyKey("feed:\(id)"), seq: nil, author: Self.author, parts: [.text(line)],
                                  createdAt: date, delivery: .committed)
        item.isReadOnly = true
        item.feedRow = self
        return item
    }

    /// `items` with `rows` merged in by time: each row goes before the first item that came after it,
    /// so the Feed reads as a running log beside the conversation. Rows newer than every item follow
    /// them; a send still on its way stays last. With `since` (the window does not reach the
    /// conversation's start), rows older than its first committed item wait until older pages load,
    /// so they never pile up above the loaded messages.
    static func inserting(_ rows: [HomeFeedRow], into items: [TranscriptItem], since: Date? = nil) -> [TranscriptItem] {
        let sorted = rows.filter { row in since.map { row.date >= $0 } ?? true }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        guard !sorted.isEmpty else { return items }
        var out: [TranscriptItem] = []
        out.reserveCapacity(items.count + sorted.count)
        var next = 0
        for item in items {
            if item.delivery == .committed {
                while next < sorted.count, sorted[next].date < item.createdAt {
                    out.append(sorted[next].item())
                    next += 1
                }
            }
            out.append(item)
        }
        // Rows after the last committed item go before any pending sends at the end.
        let tail = sorted[next...].map { $0.item() }
        guard !tail.isEmpty else { return out }
        let pending = out.lastIndex { $0.delivery == .committed }.map { out.index(after: $0) } ?? 0
        out.insert(contentsOf: tail, at: pending)
        return out
    }
}

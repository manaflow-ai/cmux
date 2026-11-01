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

    /// The row's transcript item, drawn as `author`'s read-only line (the renderer draws the words).
    func item(author: ParticipantID) -> TranscriptItem {
        let text = source.isEmpty ? title : "\(source) · \(title)"
        var item = TranscriptItem(key: IdempotencyKey("feed:\(id)"), seq: nil, author: author, parts: [.text(text)],
                                  createdAt: date, delivery: .committed)
        item.isReadOnly = true
        item.feedRow = self
        return item
    }

    /// `items` with `rows` merged in by time: each row goes before the first item that came after it,
    /// so the Feed reads as a running log beside the conversation. Rows newer than every item follow
    /// them; a send still on its way stays last.
    static func inserting(_ rows: [HomeFeedRow], into items: [TranscriptItem], author: ParticipantID) -> [TranscriptItem] {
        guard !rows.isEmpty else { return items }
        let sorted = rows.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var out: [TranscriptItem] = []
        out.reserveCapacity(items.count + sorted.count)
        var next = 0
        for item in items {
            if item.delivery == .committed {
                while next < sorted.count, sorted[next].date < item.createdAt {
                    out.append(sorted[next].item(author: author))
                    next += 1
                }
            }
            out.append(item)
        }
        // Rows after the last committed item go before any pending sends at the end.
        let tail = sorted[next...].map { $0.item(author: author) }
        guard !tail.isEmpty else { return out }
        let pending = out.lastIndex { $0.delivery == .committed }.map { out.index(after: $0) } ?? 0
        out.insert(contentsOf: tail, at: pending)
        return out
    }
}

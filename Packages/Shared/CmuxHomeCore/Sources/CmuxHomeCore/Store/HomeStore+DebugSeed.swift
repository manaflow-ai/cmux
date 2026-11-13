#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

// DEBUG and bench builds only (`CMUX_BENCH_HOOKS`): a long transcript for the pane-resize films.
extension HomeStore {
    /// The row counts ``debugSeed(_:rows:image:)`` takes.
    public static let debugSeedSizes = [50, 500, 5000]

    /// How many rows of each kind (`text`, `code`, `tool`, `image`) a seed of `rows` rows has.
    public static func debugSeedKinds(rows: Int) -> [String: Int] {
        var kinds: [String: Int] = [:]
        for (kind, count) in HomeSeedTranscript.kinds(count: rows) { kinds[kind.rawValue] = count }
        return kinds
    }

    /// FOR FILMS ONLY. Replaces the loaded window of `id` with `rows` generated messages (seq
    /// 1...`rows`, the mix of `HomeSeedTranscript`), so a pane-resize film measures a Home with a
    /// long transcript. `image` is the one prepared file every image row shows
    /// (``prepareAttachment(fileURL:keepLocation:)``); nil names a file with no bytes (tests).
    /// False, with nothing changed, when `rows` is not one of ``debugSeedSizes``, the transcript
    /// is on screen nowhere, or the owner has not answered yet (no `me`, no summary).
    ///
    /// THE SEED IS ONLY IN THIS STORE. The owner does not have the messages:
    /// - A reconnect, a gap, or a close and a new open reads the owner's tail again. The seed is
    ///   then gone, or the owner's tail lies over a part of it. Use a new home for each film.
    /// - A send typed into a seeded Home gets its seq from the owner (its own next seq), which
    ///   collides with a seeded seq. Do not send in a seeded Home.
    /// - The summary changes with it and stays changed in this store and its cache file: `lastSeq`
    ///   and `rev` are at least `rows`, the newest message is a seeded one, and my read cursor is
    ///   at `rows` (so no view reports a seeded seq to the owner as read). Owner events at or
    ///   below the seeded `rev` are ignored. One case differs: when the owner's `lastSeq` is above
    ///   `rows`, the list row keeps the owner's `lastSeq` and newest message (a summary never moves
    ///   the last message backward).
    /// - NEVER ON A REAL ACCOUNT. The list row of the conversation stays changed for good: a merge
    ///   with the owner's summary keeps the larger `lastSeq` and read cursor, and the Home cache
    ///   file stores them. Seed only in a home made for the film, and remove the Home cache of
    ///   that home after the film.
    ///
    /// It goes the way of a real read of the tail (`readTranscript`): the page into the mirror,
    /// then `confirm`, `bumpTranscript`, `settle`, `rebuildRows`. One step more comes first: the
    /// window the owner filled is ended, because a seed shorter than the loaded tail does not join
    /// it (the mirror would keep the stream stale and read the owner again).
    @discardableResult
    public func debugSeed(_ id: ConversationID, rows: Int, image: AttachmentRef? = nil) async -> Bool {
        guard Self.debugSeedSizes.contains(rows) else { return false }
        // An open's first read still running would lay the owner's tail over the seed: it ends first.
        while let reading = pager.runningLoad(id) { await reading.value }
        guard !stopped, pager.isShown(id), let me = me?.id, var summary = mirror.conversations[id] else { return false }
        let messages = HomeSeedTranscript.messages(count: rows, in: summary, me: me, image: image,
                                                   epoch: HomeSeedTranscript.epoch)
        summary.lastSeq = Seq(rows)
        summary.rev = max(mirror.revision(of: .conversation(id)), summary.rev, Revision(rows))
        summary.lastMessage = messages.last
        summary.readCursors[me] = Seq(rows)
        mirror.endTranscript(id)
        let outcome = mirror.apply(page: ConversationPage(conversation: summary, messages: messages))
        confirm([id])
        bumpTranscript(id)
        settle()
        rebuildRows()
        return outcome == .applied
    }
}
#endif

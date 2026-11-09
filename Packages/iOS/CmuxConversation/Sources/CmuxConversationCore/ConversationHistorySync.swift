import Foundation

/// What one ``ConversationTranscriptCache/sync(_:pageSize:fetch:)`` did.
public struct ConversationHistorySyncReport: Sendable, Equatable {
    /// History pages read from the server.
    public var pages: Int
    /// The stored range after the sync (nil: the conversation has no messages).
    public var range: ConversationHistoryRange?
    /// The server's history no longer held what was stored (a reset backend): it was replaced.
    public var replaced: Bool

    public init(pages: Int, range: ConversationHistoryRange?, replaced: Bool) {
        self.pages = pages
        self.range = range
        self.replaced = replaced
    }
}

extension ConversationTranscriptCache {
    /// Reads `key`'s history from the server into the device until all of it is stored, so it
    /// can be read with no network.
    ///
    /// 1. Catch up: the newest pages, down to the newest message already stored, are written in
    ///    one transaction (a reconnect after the app was away). An interrupted catch-up writes
    ///    nothing and the next one starts over.
    /// 2. Backfill: older pages below the oldest stored message, each written in one transaction
    ///    together with the new oldest seq, so an interrupted backfill resumes where it stopped.
    ///
    /// Every write is by message id, so a retry, a repeated reconnect or a page read twice never
    /// duplicates a row. Throws the fetch's error (the caller retries) or `CancellationError`
    /// when the task is cancelled or the account changed or signed out meanwhile; nothing is
    /// written into another account's history.
    public func sync(_ key: String, pageSize: Int = 200,
                     fetch: @escaping @Sendable (_ beforeSeq: Int?, _ limit: Int) async throws -> ConversationHistoryPage)
        async throws -> ConversationHistorySyncReport {
        let scope = scope
        var stored = try await run(scope) { try $0.syncedRange(key) }
        var pages = 0

        // 1. Catch up from the newest message.
        var page = try await fetch(nil, pageSize)
        try Task.checkCancellation()
        pages += 1
        guard let newest = page.messages.compactMap(\.seq).max() else {
            // An empty conversation: nothing to store, and nothing stored is still true.
            if stored != nil { try await run(scope) { try $0.forget(key) } }
            return ConversationHistorySyncReport(pages: pages, range: nil, replaced: stored != nil)
        }
        var fetched = page.messages
        var oldestFetched = page.messages.compactMap(\.seq).min() ?? newest
        var hasMore = page.hasMore
        var replaced = false
        if let current = stored {
            if newest < current.newestSeq {
                replaced = true
            } else {
                while hasMore, oldestFetched > current.newestSeq {
                    page = try await fetch(oldestFetched, pageSize)
                    try Task.checkCancellation()
                    pages += 1
                    guard let next = page.messages.compactMap(\.seq).min(), next < oldestFetched else {
                        throw ConversationBackendError(code: -1, message: "History made no progress while syncing")
                    }
                    fetched += page.messages
                    oldestFetched = next
                    hasMore = page.hasMore
                }
                // History starts above what is stored: it is not the history that was stored.
                if oldestFetched > current.newestSeq, !hasMore { replaced = true }
            }
        }
        if replaced {
            try await run(scope) { try $0.forget(key) }
            stored = nil
        }
        var range = stored.map { ConversationHistoryRange(oldestSeq: min($0.oldestSeq, oldestFetched), newestSeq: max($0.newestSeq, newest),
                                                          complete: $0.complete || (!hasMore && oldestFetched <= $0.oldestSeq)) }
            ?? ConversationHistoryRange(oldestSeq: oldestFetched, newestSeq: newest, complete: !hasMore)
        let caughtUp = fetched, newRange = range
        try await run(scope) { try $0.write(key, messages: caughtUp, range: .some(newRange)) }

        // 2. Backfill below the oldest stored message.
        while !range.complete {
            try Task.checkCancellation()
            page = try await fetch(range.oldestSeq, pageSize)
            try Task.checkCancellation()
            pages += 1
            let below = page.messages.filter { ($0.seq ?? .max) < range.oldestSeq }
            if let next = below.compactMap(\.seq).min() {
                range.oldestSeq = next
                range.complete = !page.hasMore
            } else if !page.hasMore {
                range.complete = true
            } else {
                throw ConversationBackendError(code: -1, message: "History made no progress while syncing")
            }
            let rows = below, step = range
            try await run(scope) { try $0.write(key, messages: rows, range: .some(step)) }
        }
        return ConversationHistorySyncReport(pages: pages, range: range, replaced: replaced)
    }
}

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
    /// 1. Catch up: the newest pages, down to the newest message already stored (a reconnect
    ///    after the app was away). Each page's rows are written as they arrive; the range moves
    ///    once the gap is closed, so an interrupted catch-up keeps its rows and re-reads only pages.
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

        // 1. Catch up from the newest message. Each page's rows are written as they arrive (by
        // id, so a retry rewrites them harmlessly); the range moves only once the gap is closed.
        var page = try await fetch(nil, pageSize)
        try Task.checkCancellation()
        pages += 1
        guard let newest = page.messages.compactMap(\.seq).max() else {
            // An empty page (a backend still starting, or an empty conversation): nothing new,
            // and what is stored stays; only the server's history replacing it removes it.
            return ConversationHistorySyncReport(pages: pages, range: stored, replaced: false)
        }
        var fetched = page.messages
        var oldestFetched = page.messages.compactMap(\.seq).min() ?? newest
        var hasMore = page.hasMore
        try await run(scope) { [rows = page.messages] in try $0.write(key, messages: rows) }
        if let current = stored {
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
                try await run(scope) { [rows = page.messages] in try $0.write(key, messages: rows) }
            }
        }
        // The server's history no longer holds what is stored (a reset backend): the pages
        // reached the stored range yet hold none of its messages, or history ends above it.
        // A newest message deleted on the server (a lower newest seq) is not a reset.
        var replaced = false
        if let current = stored {
            let reached = oldestFetched <= current.newestSeq
            let ids = fetched.filter { ($0.seq ?? .max) <= current.newestSeq }.map(\.id)
            if reached {
                replaced = try await run(scope) { try !$0.containsAny(key, ids: ids) }
            } else {
                replaced = !hasMore
            }
        }
        if replaced {
            let rows = fetched
            try await run(scope) { db in
                try db.forget(key)
                try db.write(key, messages: rows)
            }
            stored = nil
        }
        let caughtUp = ConversationHistoryRange(oldestSeq: oldestFetched, newestSeq: newest,
                                                complete: !hasMore)
        // Contiguous with what is stored: the gap is closed, the range widens.
        var range = try await run(scope) { db -> ConversationHistoryRange in
            try db.merge(key, messages: [], range: caughtUp)
            return try db.syncedRange(key) ?? caughtUp
        }

        // 2. Backfill below the oldest stored message.
        while !range.complete {
            try Task.checkCancellation()
            page = try await fetch(range.oldestSeq, pageSize)
            try Task.checkCancellation()
            pages += 1
            let below = page.messages.filter { ($0.seq ?? .max) < range.oldestSeq }
            var step = range
            if let next = below.compactMap(\.seq).min() {
                step.oldestSeq = next
                step.complete = !page.hasMore
            } else if !page.hasMore {
                step.complete = true
            } else {
                throw ConversationBackendError(code: -1, message: "History made no progress while syncing")
            }
            range = try await run(scope) { [step] db -> ConversationHistoryRange in
                try db.merge(key, messages: below, range: step)
                return try db.syncedRange(key) ?? step
            }
        }
        return ConversationHistorySyncReport(pages: pages, range: range, replaced: replaced)
    }
}

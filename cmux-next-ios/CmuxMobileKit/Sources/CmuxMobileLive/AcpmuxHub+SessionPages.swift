import CmuxConnectivityTelemetry
import CmuxMobileAgentChat
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// The chat list in pages (CMUX-563, after CMUX-49). The phone used to read the Mac's whole
/// list before it was ready: about 2.7 KB a chat, so a Mac with 500 chats sent 1.3 MB (and
/// one with tools on, 24 MB) through the link before the Feed or any chat could show, and on a
/// slow network the app sat on its loading screen. Now `_acpmux/watch` asks for the newest
/// ``firstPageRows`` (acpmux `Snapshot::page`, newest first, with the `nextCursor` of the rest),
/// the hub is ready with them, and the rest is read after, page by page, on the same
/// connection. An older acpmux that ignores `limit` answers whole, with no cursor: as before.
extension AcpmuxHub {
    /// Rows of the watch's first page: more than any first screen shows (Feed, chat lists).
    nonisolated static let firstPageRows = 100
    /// Rows of each later page.
    nonisolated static let laterPageRows = 500
    /// Tries of one later page before the rest stops (acpmux paces lists: `list.paced`).
    nonisolated static let pageTries = 4

    /// The watch, on, with the newest ``firstPageRows`` rows and the cursor of the rest (nil:
    /// the list is whole).
    nonisolated static func firstPage(_ connection: AcpmuxConnection, timeout: Duration) async throws -> (rows: [JSONValue], cursor: String?) {
        let reply = try await connection.request("_acpmux/watch", .object([
            "enabled": .bool(true), "limit": .number(Double(firstPageRows)),
        ]), timeout: timeout)
        return (try AcpmuxConnection.pageRows(reply), try AcpmuxConnection.nextCursor(reply))
    }

    /// Puts the first page in `sessions` and returns its ids. A whole list replaces what an
    /// earlier connection left; a first page keeps those rows until the rest is read
    /// (``readRest(after:on:firstPage:timeout:)`` lets go of the ones gone), so a reconnect
    /// does not hide older chats for a moment. A row a notice already told is older than the
    /// notice, and a chat purged since the watch began stays gone.
    func applyFirstPage(_ rows: [JSONValue], whole: Bool) -> Set<String> {
        var next = whole ? [:] : sessions
        var ids: Set<String> = []
        for value in rows {
            guard let session = AcpmuxSession(value), !purgedSinceWatch.contains(session.id) else { continue }
            ids.insert(session.id)
            next[session.id] = toldSinceWatch.contains(session.id) ? sessions[session.id] ?? session : session
        }
        if whole {
            for id in toldSinceWatch where next[id] == nil { next[id] = sessions[id] }
        }
        sessions = next
        listWhole = whole
        return ids
    }

    /// Reads the list after `cursor` while `connection` is this hub's, adding each row a notice
    /// has not told already and that was not purged since. Once whole, the chats it does not
    /// list (gone while the phone was away) are let go, the Feed reads the whole list again,
    /// and the asks open in chats past the first page are read. A page acpmux refuses or that
    /// times out is asked again (after `retryAfterMs` when acpmux paces it) up to ``pageTries``
    /// times; then the rest stops, and the rows an earlier connection left that this one did
    /// not read are let go, since their state (a pending ask, a status) may be stale.
    func readRest(after cursor: String, on connection: AcpmuxConnection, firstPage: Set<String>, timeout: Duration) async {
        var listed = firstPage
        var cursors: Set<String> = [cursor]
        var next: String? = cursor
        var pages = 0
        while let page = next {
            guard let reply = await laterPage(page, on: connection, timeout: timeout) else {
                await restStopped(on: connection, listed: listed, firstPage: firstPage, after: pages, timeout: timeout)
                return
            }
            guard !Task.isCancelled, self.connection === connection else { return }
            pages += 1
            let rows: [JSONValue]
            do {
                rows = try AcpmuxConnection.pageRows(reply)
                next = try AcpmuxConnection.nextCursor(reply)
            } catch {
                log.error("acpmux list page unreadable: \(String(describing: error), privacy: .public)")
                await restStopped(on: connection, listed: listed, firstPage: firstPage, after: pages, timeout: timeout)
                return
            }
            for value in rows {
                guard let session = AcpmuxSession(value) else { continue }
                listed.insert(session.id)
                guard !toldSinceWatch.contains(session.id), !purgedSinceWatch.contains(session.id) else { continue }
                sessions[session.id] = session
            }
            if let repeated = next, !cursors.insert(repeated).inserted {
                log.error("acpmux sent the session list cursor \(repeated, privacy: .public) again")
                await restStopped(on: connection, listed: listed, firstPage: firstPage, after: pages, timeout: timeout)
                return
            }
        }
        // A dropped notice may have been about a chat that moved above the cursor: none is let go.
        if !droppedSinceWatch {
            sessions = sessions.filter { listed.contains($0.key) || toldSinceWatch.contains($0.key) }
        }
        listWhole = true
        log.info("acpmux list whole, \(self.sessions.count, privacy: .public) sessions in \(pages + 1, privacy: .public) pages")
        ConnectivityTelemetry.shared.record(.hub, "list_whole", outcome: .success, fields: [
            "sessions": .number(Double(sessions.count)), "pages": .number(Double(pages + 1)),
        ])
        onWatchEvent?(.sessionsLoaded(Array(sessions.values)))
        await seedPending(connection, requestTimeout: timeout, among: listed.subtracting(firstPage))
    }

    /// The rest stopped short on a live connection: rows an earlier connection left that this
    /// one did not read are let go (their state, a pending ask or a status, may be stale), and
    /// the asks of the pages that were read are seeded. A connection that closed meanwhile lets
    /// nothing go: its rows stay for the next connection's first page.
    private func restStopped(on connection: AcpmuxConnection, listed: Set<String>, firstPage: Set<String>, after pages: Int, timeout: Duration) async {
        guard !Task.isCancelled, !(await connection.isClosed), self.connection === connection else { return }
        log.error("acpmux list rest stopped after \(pages, privacy: .public) pages")
        sessions = sessions.filter { listed.contains($0.key) || toldSinceWatch.contains($0.key) }
        onWatchEvent?(.sessionsLoaded(Array(sessions.values)))
        await seedPending(connection, requestTimeout: timeout, among: listed.subtracting(firstPage))
    }

    /// One later page, asked up to ``pageTries`` times; nil when every try failed, the
    /// connection was replaced, or the read was cancelled. A paced refusal waits the
    /// `retryAfterMs` acpmux names (at most 30 s), any other failure one second, then two.
    private func laterPage(_ cursor: String, on connection: AcpmuxConnection, timeout: Duration) async -> JSONValue? {
        for attempt in 1...Self.pageTries {
            do {
                return try await connection.request("_acpmux/sessions", .object([
                    "limit": .number(Double(Self.laterPageRows)), "cursor": .string(cursor),
                ]), timeout: timeout)
            } catch {
                guard attempt < Self.pageTries, !Task.isCancelled, self.connection === connection, !(await connection.isClosed) else { return nil }
                let paced = (error as? AcpmuxConnection.RPCError)?.retryAfterMs
                let wait = Duration.milliseconds(min(paced ?? 1000 * attempt, 30_000))
                log.info("acpmux list page \(attempt, privacy: .public) failed, again in \(String(describing: wait), privacy: .public): \(String(describing: error), privacy: .public)")
                // A bounded backoff between tries of a request acpmux paced, not a synchronization.
                do { try await Task.sleep(for: wait) } catch { return nil }
            }
        }
        return nil
    }
}

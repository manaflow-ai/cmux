#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import CmuxMobileAgentChat
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// The one-request catch-up (`catch-up` link service, `LiveCoordinator+CatchUp.swift`) into the
/// hub: the reply's chat list and chat pages go in through the paths the hub's own watch and
/// attaches use, so a chat the person opens after a wake shows what the reply brought, with no
/// second parser and no second notion of a gap.
extension AcpmuxHub {
    /// The open chats and the last event each holds, for a `catch-up` request (each once).
    func catchUpChats() -> [(sessionID: String, lastSeq: Int)] {
        var seen = Set<String>()
        return liveSources.compactMap { source in
            seen.insert(source.sessionID).inserted ? (source.sessionID, source.heldSeq) : nil
        }
    }

    /// Applies a catch-up reply's chat list and chat pages; returns the chats whose page went in.
    ///
    /// `chatList`: the `_acpmux/watch` result. A follow (`follow: true`) changes the rows it
    /// lists and lets go of the ones in `gone`; a first page (`reset` when the cursor was stale)
    /// goes in as the watch's first page does (``applyFirstPage(_:whole:)``). Nil (the list was
    /// cut, or not asked) changes nothing. Once this hub's own watch is ready its rows are newer
    /// than any catch-up, and the list is left as it is.
    ///
    /// `pages`: each chat's `_acpmux/attach` result, newest screenful first. Each open source
    /// of the chat applies it as an attach's reply (``AcpmuxSessionSource/applyCatchUpPage(_:)``):
    /// a page past the records held opens the gap that fills, never a hole, and older records
    /// come on scroll. A chat with no open source, or one attached already, is left alone.
    @discardableResult
    func applyCatchUp(chatList: JSONValue?, pages: [(sessionID: String, result: JSONValue)]) async -> Set<String> {
        if let chatList, !isReady { applyCatchUpList(chatList) }
        var applied: Set<String> = []
        for page in pages {
            for source in liveSources(of: page.sessionID) where await source.applyCatchUpPage(page.result) {
                applied.insert(page.sessionID)
            }
        }
        if !applied.isEmpty {
            log.info("catch-up applied \(applied.count, privacy: .public) of \(pages.count, privacy: .public) chat pages")
        }
        return applied
    }

    /// The catch-up's `_acpmux/watch` result into `sessions`.
    private func applyCatchUpList(_ list: JSONValue) {
        let rows = list["sessions"]?.arrayValue ?? []
        guard list["follow"] == .bool(true) else {
            // A first page (or the list again after a stale cursor): as the watch's own.
            guard list["sessions"]?.arrayValue != nil, let cursor = try? AcpmuxConnection.nextCursor(list) else { return }
            if applyFirstPage(rows, whole: cursor == nil).changed {
                onWatchEvent?(.sessionsLoaded(Array(sessions.values)))
            }
            return
        }
        let previous = sessions
        var next = sessions
        for value in rows {
            guard let session = AcpmuxSession(value) else { continue }
            next[session.id] = session
        }
        // `gone` lists rows (`{"sessionId": …}`); a bare id is read too.
        for gone in list["gone"]?.arrayValue ?? [] {
            if let id = gone["sessionId"]?.stringValue ?? gone.stringValue { next[id] = nil }
        }
        guard next != previous else { return }
        sessions = next
        onWatchEvent?(.sessionsLoaded(Array(next.values)))
    }
}

#if canImport(CmuxMobileLinkFFI)
extension AcpmuxHub {
    /// ``applyCatchUp(chatList:pages:)`` over the FFI's answer: `chatListJSON` and each page's
    /// `pageJson` as Rust read them (`catch_up::service::read`). A page whose JSON does not read
    /// is skipped; `cut` names (`chatList`, `chats:<id>`) are skipped too, though Rust already
    /// leaves them out.
    @discardableResult
    func applyCatchUp(chatListJSON: String?, chats: [CatchUpChatPage], cut: [CatchUpCut] = []) async -> Set<String> {
        let cutNames = Set(cut.map(\.name))
        let list = cutNames.contains("chatList") ? nil : chatListJSON.flatMap(Self.catchUpJSON)
        let pages = chats.compactMap { page -> (sessionID: String, result: JSONValue)? in
            guard !cutNames.contains("chats:\(page.sessionId)"), let result = Self.catchUpJSON(page.pageJson) else { return nil }
            return (page.sessionId, result)
        }
        return await applyCatchUp(chatList: list, pages: pages)
    }

    nonisolated static func catchUpJSON(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
#endif

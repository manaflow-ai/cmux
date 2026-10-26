import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine

/// Which conversations classic Home lists and opens on.
extension TopHomePageView {
    /// The rows the list shows: an archived Chief's conversation is hidden
    /// (its history stays with the owner, read-only).
    static func visible(_ rows: [InboxRow], archivedChiefs: Set<String>, me: ParticipantID?) -> [InboxRow] {
        guard !archivedChiefs.isEmpty else { return rows }
        return rows.filter { row in
            guard row.kind == .chief else { return true }
            return !row.summary.participants.contains { $0.id != me && archivedChiefs.contains($0.id.rawValue) }
        }
    }

    /// The Chief conversation Home opens on: the chief placed on a server takes over a local one
    /// without history (`HomeChiefSource`).
    static func chief(_ home: HomeService) -> String? {
        let local = HomeChiefName.select(from: home.conversations)
        return home.tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: home.hostedChief.choice)
    }

    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation.
    func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        return rows.homeLines.lazy.compactMap(\.conversation).first
    }

    /// The shown conversation is one the owner's own inbox does not have:
    /// the cache's conversation of a Chief home made again at the same path
    /// (cx-ebm.55). Decided only on the owner's inbox, never the cache's copy.
    func shownIsGone(_ store: HomeStore) -> Bool {
        guard let shown else { return false }
        return store.isInboxCurrent && store.isCacheOnly(shown)
    }

    /// Shows the live Chief instead of a gone conversation; the text and pictures the user
    /// put there go with it (after the Chief's own draft), so nothing typed or pasted is lost.
    func replaceGone(with chief: ConversationID, store: HomeStore) {
        guard let gone = shown, gone != chief, store.summary(chief) != nil else { return }
        let pictures = store.draftAttachments(for: gone)
        if !pictures.isEmpty {
            let own = store.draftAttachments(for: chief)
            store.setDraftAttachments(own + pictures.filter { p in !own.contains { $0.ref.hash == p.ref.hash } }, for: chief)
            store.setDraftAttachments([], for: gone)
        }
        let text = store.draft(for: gone) ?? ""
        if !text.isEmpty {
            let own = store.draft(for: chief) ?? ""
            store.setDraft(own.isEmpty ? text : own + "\n" + text, for: chief)
            store.setDraft("", for: gone)
        }
        // Its view says the Chief restarted and that Return sends what was carried.
        if !text.isEmpty || !pictures.isEmpty { store.noteCarriedDraft(to: chief) }
        show(chief)
    }
}

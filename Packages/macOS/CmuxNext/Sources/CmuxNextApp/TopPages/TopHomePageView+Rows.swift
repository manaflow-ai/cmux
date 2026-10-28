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

    /// The Chief conversation Home opens on: the preferred Chief (``HomeService/defaultChiefConversation``;
    /// the chief placed on a server takes over a local one without history, `HomeChiefSource`).
    static func chief(_ home: HomeService) -> String? { home.defaultChiefConversation }

    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation that the
    /// Engine row does not exclude (with This Mac chosen, never a cloud Chief's: ``HomeService/excludedChiefConversations``).
    static func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        let excluded = home.excludedChiefConversations
        return rows.homeLines.lazy.compactMap(\.conversation).first { !excluded.contains($0.rawValue) }
    }

    /// What the Chief observation watches: the preferred Chief and whether this Mac's Chief is the
    /// choice. The Engine row changes the choice while the preferred Chief stays nil (the cloud
    /// read has not landed and this Mac's Chief is not listed yet), and the page must reconcile
    /// what it opened by itself then too, so the choice is part of what it watches.
    struct ChiefKey: Equatable {
        var chief: String?
        var prefersLocal: Bool
    }

    static func chiefKey(_ home: HomeService) -> ChiefKey {
        ChiefKey(chief: chief(home), prefersLocal: home.prefersLocalChief)
    }

    /// What the page does when the preferred Chief changes, and which Chief it follows afterwards.
    struct ChiefFollowUp: Equatable {
        /// The conversation to open; nil: what is shown stays.
        var open: ConversationID?
        /// The Chief conversation the page opened by itself, which a later Chief replaces. What the
        /// person picked themselves is never replaced, so it is not this.
        var followed: String?
    }

    /// The preferred Chief is now `chief` (``HomeService/defaultChiefConversation``), the page
    /// shows `shown`, and `followed` is what it last opened by itself. Pure, so the whole
    /// transition is under test: the Engine row's switch to This Mac goes through a stretch with no
    /// Chief at all, and the Chief that arrives after it must still open.
    static func followUp(chief: String?, shown: ConversationID?, followed: String?, composing: Bool,
                         rows: [InboxRow], home: HomeService) -> ChiefFollowUp {
        // Only what the page opened itself is ever replaced: the conversation the person picked
        // stays, and so does the New Message page, which `show(_:)` would leave.
        let mine = !composing && (shown == nil || shown?.rawValue == followed)
        guard let chief else {
            // No Chief to open: This Mac was picked while its Chief is not listed yet. The cloud
            // Chief on screen is one the Engine row now excludes, so the page leaves it for the
            // first conversation the row allows. `followed` stays whatever it was, so the Chief
            // that arrives next still replaces what this left behind.
            guard mine, let next = replacementForExcluded(shown: shown, rows: rows, home: home) else {
                // Nothing the row allows is listed, the person is on a conversation of their own,
                // or the New Message page is up: what is shown stays, rather than leave an empty
                // window or take the person off what they opened.
                return ChiefFollowUp(open: nil, followed: followed)
            }
            return ChiefFollowUp(open: next, followed: next.rawValue)
        }
        // Following only what it actually opened: a Chief it left the person alone for is not
        // theirs to be taken off later. Auto makes that sequence ordinary — the person opens the
        // Hosted Chief while this Mac's brain runs, that brain dies so Hosted becomes preferred
        // (nothing opens, they are already there), and its restart must not move them.
        guard mine else { return ChiefFollowUp(open: nil, followed: followed) }
        return ChiefFollowUp(open: ConversationID(chief), followed: chief)
    }

    /// What the page shows once there is no Chief conversation at all: the first conversation the
    /// Engine row allows, but only when what is shown is one it excludes (a cloud Chief after This
    /// Mac was picked). nil: what is shown stays, which is every other case.
    static func replacementForExcluded(shown: ConversationID?, rows: [InboxRow], home: HomeService) -> ConversationID? {
        guard let shown, home.excludedChiefConversations.contains(shown.rawValue),
              let next = defaultConversation(rows: rows, home: home), next != shown else { return nil }
        return next
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

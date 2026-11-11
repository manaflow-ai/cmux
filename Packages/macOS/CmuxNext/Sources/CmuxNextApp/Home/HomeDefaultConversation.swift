import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextHomeEngine
import Observation

/// Which conversation Home opens by itself (its Chief's, else the first the Engine row allows), and
/// how it follows the preferred Chief as it changes, for the Messages page (``HomeMessagesPage``).
/// Pure over `HomeService`'s state, so every transition is under test.
@MainActor
enum HomeDefaultConversation {
    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation that the
    /// Engine row does not exclude (with This Mac chosen, never a cloud Chief's: ``HomeService/excludedChiefConversations``).
    static func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        let excluded = home.excludedChiefConversations
        return rows.homeLines.lazy.compactMap(\.conversation).first { !excluded.contains($0.rawValue) }
    }

    /// An archived Chief's conversation: listed by the store, left out of `rows` (``HomeArchivedChiefs``).
    static func isHidden(_ id: ConversationID, rows: [InboxRow], home: HomeService) -> Bool {
        home.homeStore.rows.contains { $0.id == id } && !rows.contains { $0.id == id }
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

    /// What the page does when it says what it shows (`cmux.home.messages.selected`): nothing shown
    /// (its first read of the inbox, a conversation that left the list) opens the default
    /// conversation, which it then follows; New Message (`composing`) is the person's page and stays,
    /// as does a conversation they opened. One rule for the first load and every later one.
    static func afterShown(_ shown: ConversationID?, composing: Bool, followed: String?,
                           rows: [InboxRow], home: HomeService) -> ChiefFollowUp {
        guard !composing else { return ChiefFollowUp(open: nil, followed: followed) }
        guard let shown else {
            guard let first = defaultConversation(rows: rows, home: home) else { return ChiefFollowUp(open: nil, followed: followed) }
            return ChiefFollowUp(open: first, followed: first.rawValue)
        }
        return ChiefFollowUp(open: nil, followed: shown.rawValue == followed ? followed : nil)
    }

    /// The page left `id` while it showed it (Delete Conversation from List): its neighbor in the
    /// list shows, else the default conversation. A neighbor the Engine row excludes (a cloud Chief
    /// under This Mac) is not one: the default conversation decides instead. nil: nothing else to show.
    static func replacement(leaving id: ConversationID, next: ConversationID?, rows: [InboxRow], home: HomeService) -> ConversationID? {
        let excluded = home.excludedChiefConversations
        let neighbor = next.flatMap { $0 == id || excluded.contains($0.rawValue) ? nil : $0 }
        let fallback = neighbor ?? defaultConversation(rows: rows.filter { $0.id != id }, home: home)
        return fallback == id ? nil : fallback
    }

    /// The preferred Chief's conversation, unless Archive Chief hid it (``HomeArchivedChiefs/openable(_:listed:)``).
    static func chief(_ home: HomeService) -> String? {
        HomeArchivedChiefs(home.directory.archivedChiefs, me: home.homeStore.me?.id)
            .openable(home.defaultChiefConversation, listed: home.homeStore.rows,
                      participants: { home.participants(of: $0).map(\.id) })
    }
}

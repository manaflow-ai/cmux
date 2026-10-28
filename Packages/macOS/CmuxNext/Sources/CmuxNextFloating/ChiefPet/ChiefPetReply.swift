import Foundation

/// Who the pet's reply box talks to: the Chief, or the tab of a notice over the pet.
public enum ChiefPetReplyTarget: Equatable {
    case chief
    case notice(ChiefPetNotice)
}

/// What the App does for the pet: open a target (the Chief's Home, a notice's tab or agent chat),
/// send typed text to one (false when it could not), and the right-click menu's two items:
/// open the pet's settings, and hide the pet (`home.chiefPetEnabled` off), offered only while
/// `canHide` (not while the setting is managed).
public struct ChiefPetActions {
    public var open: @MainActor (ChiefPetReplyTarget) -> Void
    public var send: @MainActor (ChiefPetReplyTarget, String) async -> Bool
    public var openSettings: @MainActor () -> Void
    public var hide: @MainActor () -> Void
    public var canHide: @MainActor () -> Bool

    public init(open: @escaping @MainActor (ChiefPetReplyTarget) -> Void,
                send: @escaping @MainActor (ChiefPetReplyTarget, String) async -> Bool,
                openSettings: @escaping @MainActor () -> Void = {},
                hide: @escaping @MainActor () -> Void = {},
                canHide: @escaping @MainActor () -> Bool = { true }) {
        self.open = open
        self.send = send
        self.openSettings = openSettings
        self.hide = hide
        self.canHide = canHide
    }
}

/// The reply box's choices and what Return does. Pure.
struct ChiefPetReply: Equatable {
    /// What a Return in the box does.
    enum Submit: Equatable {
        case send(ChiefPetReplyTarget, String)
        case open(ChiefPetReplyTarget)
        case nothing
    }

    /// The notices over the pet, newest first, then the Chief: the box starts on the newest.
    static func targets(_ feed: ChiefPetFeed) -> [ChiefPetReplyTarget] {
        feed.notices.map(ChiefPetReplyTarget.notice) + [.chief]
    }

    /// Return sends the text to the Chief or into a terminal; for a notice that takes no typed
    /// reply (an agent chat, another tab) it opens it. ⌘Return always opens the target.
    static func submit(_ target: ChiefPetReplyTarget, text: String, command: Bool) -> Submit {
        if command { return .open(target) }
        if case .notice(let notice) = target, notice.reply != .type { return .open(target) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .nothing : .send(target, trimmed)
    }

    /// The same target across a refresh: the Chief, or a notice of the same tab (its id may be newer).
    static func sameTarget(_ a: ChiefPetReplyTarget, _ b: ChiefPetReplyTarget) -> Bool {
        switch (a, b) {
        case (.chief, .chief): true
        case (.notice(let x), .notice(let y)): x.tab == y.tab
        default: false
        }
    }

    /// The field's placeholder for `target`.
    static func placeholder(_ target: ChiefPetReplyTarget) -> String {
        switch target {
        case .chief: ChiefPetStrings.messageChief
        case .notice(let notice) where notice.reply == .type: ChiefPetStrings.reply(to: notice.title)
        case .notice(let notice): ChiefPetStrings.returnOpens(notice.title)
        }
    }

    /// The target menu's title for `target`.
    static func title(_ target: ChiefPetReplyTarget) -> String {
        switch target {
        case .chief: ChiefPetStrings.accessibilityLabel
        case .notice(let notice): notice.title
        }
    }
}

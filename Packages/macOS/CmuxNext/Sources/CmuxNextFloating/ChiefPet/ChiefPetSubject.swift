public import Foundation
public import Observation

/// Which chat the Chief pet (the floating mini) stands for: the Chief, or an agent chat the person
/// picked with Show in Mini (Leo 2026-11-07: "we point it not necessarily at the chief, but at a
/// particular coordinator chat"). The mini then wears that chat's avatar, draws its turn state, and
/// its reply box talks to it. Kept in user defaults beside the mini's spot (`ChiefPetPlacement`):
/// it is the mini's own window state, not a cmux.json preference. Nil is the Chief, the default.
@Observable @MainActor
public final class ChiefPetSubject {
    /// An acpmux session on the machine `host` (`install:<id>`).
    public nonisolated struct Chat: Equatable, Hashable, Sendable {
        public var host: String
        public var session: String

        public init(host: String, session: String) {
            self.host = host
            self.session = session
        }
    }

    static let key = "chiefPet.chat"

    /// The chat the mini shows; nil for the Chief.
    public private(set) var chat: Chat?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.key) as? [String: String], let host = saved["host"],
           let session = saved["session"], !host.isEmpty, !session.isEmpty {
            chat = Chat(host: host, session: session)
        }
    }

    /// Show in Mini for `chat`; nil gives the mini back to the Chief. Saved at once.
    public func show(_ chat: Chat?) {
        guard chat != self.chat else { return }
        self.chat = chat
        if let chat {
            defaults.set(["host": chat.host, "session": chat.session], forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }

    /// Whether the mini shows session `session` now.
    public func shows(session: String) -> Bool { chat?.session == session }
}

/// What the mini shows of its chat (``ChiefPetSubject``), as the App reads it: the chat (nil for the
/// Chief), its title, and its newest reply for the reply box (nil: none known).
public nonisolated struct ChiefPetHome: Equatable, Sendable {
    public var chat: ChiefPetSubject.Chat?
    public var title: String
    public var latest: String?

    public init(chat: ChiefPetSubject.Chat?, title: String, latest: String? = nil) {
        self.chat = chat
        self.title = title
        self.latest = latest
    }

    /// The Chief, with no reply shown.
    public static let chief = ChiefPetHome(chat: nil, title: "")

    /// Who the reply box talks to for it.
    @MainActor var target: ChiefPetReplyTarget {
        guard let chat else { return .chief }
        return .chat(chat, title: title)
    }
}

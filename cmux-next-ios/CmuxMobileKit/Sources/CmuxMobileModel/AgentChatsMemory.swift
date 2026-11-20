import Foundation

/// Each Mac's Agent Chats list as this run last read it, so the list opened again shows its rows
/// at once (with a refresh under way) instead of a spinner on every open (the user, 2026-11-09:
/// "never show an empty UI for data that exists but is still loading"). Memory only, a few Macs,
/// the pages loaded so far with the cursor after them; sign-out forgets it (``removeAll()``).
@MainActor
public final class AgentChatsMemory {
    public static let shared = AgentChatsMemory()

    /// Macs remembered: the ones listed most recently stay.
    public let macLimit: Int
    private var pages: [String: AgentChatPage] = [:]
    /// Mac ids, least recently kept first.
    private var order: [String] = []

    public init(macLimit: Int = 8) {
        self.macLimit = macLimit
    }

    /// The chats last listed for `macID`, and the cursor after them.
    public func page(for macID: String) -> AgentChatPage? { pages[macID] }

    /// Keeps `page` (the chats listed so far and the cursor after them) for `macID`.
    public func keep(_ page: AgentChatPage, for macID: String) {
        pages[macID] = page
        order.removeAll { $0 == macID }
        order.append(macID)
        while order.count > macLimit { pages[order.removeFirst()] = nil }
    }

    /// Sign-out: no chat of the account stays.
    public func removeAll() {
        pages = [:]
        order = []
    }
}

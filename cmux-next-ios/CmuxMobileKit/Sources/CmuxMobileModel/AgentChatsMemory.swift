import Foundation

/// Each Mac's Agent Chats list as this phone last read it, so the list opened again shows its rows
/// at once (with a refresh under way) instead of a spinner on every open (the user, 2026-11-09:
/// "never show an empty UI for data that exists but is still loading"). In memory: a few Macs, the
/// pages loaded so far with the cursor after them. On the phone (``AgentChatsDisk``, the Rust
/// read-first store): each account's first page per Mac, so a cold launch draws it too before the
/// Mac answers (Leo, 2026-11-22: "being able to sync up my phone reading from mac but also from
/// what the phone itself is storing"). Sign-out forgets both (``removeAll()``).
@MainActor
public final class AgentChatsMemory {
    public static let shared = AgentChatsMemory()

    /// Macs remembered: the ones listed most recently stay.
    public let macLimit: Int
    /// Chats kept on the phone per Mac: the first screen, so the stored copy stays small and
    /// constant as a Mac's chats grow.
    public static let storedChatLimit = 60
    private var pages: [String: AgentChatPage] = [:]
    /// Mac ids, least recently kept first.
    private var order: [String] = []
    /// Where the first page of each Mac's list stays across launches (nil: memory only).
    private var disk: (any AgentChatsDisk)?
    /// The signed-in account, whose list the disk reads and writes (nil: none).
    private var accountID: @MainActor () -> String? = { nil }

    public init(macLimit: Int = 8, disk: (any AgentChatsDisk)? = nil,
                accountID: @escaping @MainActor () -> String? = { nil }) {
        self.macLimit = macLimit
        self.disk = disk
        self.accountID = accountID
    }

    /// Keeps each Mac's first page on `disk` too, for the account `accountID` names (the app sets
    /// this once at launch).
    public func persist(to disk: any AgentChatsDisk, accountID: @escaping @MainActor () -> String?) {
        self.disk = disk
        self.accountID = accountID
    }

    /// The chats last listed for `macID`, and the cursor after them: this run's, else the ones the
    /// phone stored for the account (one small bounded read).
    public func page(for macID: String) -> AgentChatPage? {
        if let held = pages[macID] { return held }
        guard let disk, let account = accountID(), !account.isEmpty,
              let data = disk.read(account: account, macID: macID),
              let stored = try? JSONDecoder().decode(StoredPage.self, from: data) else { return nil }
        let page = stored.page
        guard !page.chats.isEmpty else { return nil }
        remember(page, for: macID)
        return page
    }

    /// Keeps `page` (the chats listed so far and the cursor after them) for `macID`.
    public func keep(_ page: AgentChatPage, for macID: String) {
        remember(page, for: macID)
        guard let disk, let account = accountID(), !account.isEmpty else { return }
        // Only the first screen stays on the phone; a cut list keeps no cursor (the refresh on open
        // brings the Mac's own).
        let cut = page.chats.count > Self.storedChatLimit
        let stored = StoredPage(AgentChatPage(chats: Array(page.chats.prefix(Self.storedChatLimit)),
                                              nextCursor: cut ? nil : page.nextCursor))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        disk.write(data, account: account, macID: macID)
    }

    /// Sign-out: no chat of the account stays, in memory or on the phone.
    public func removeAll() {
        pages = [:]
        order = []
        disk?.removeAll()
    }

    private func remember(_ page: AgentChatPage, for macID: String) {
        pages[macID] = page
        order.removeAll { $0 == macID }
        order.append(macID)
        while order.count > macLimit { pages[order.removeFirst()] = nil }
    }
}

/// Where the Agent Chats list's first page stays across launches: the Rust read-first store
/// (`PhoneReadStore`, cmux-mobile-core `read_store`), keyed by account, Mac and surface. Reads
/// are small and bounded; writes and removals may finish later, in order.
public protocol AgentChatsDisk: AnyObject, Sendable {
    func read(account: String, macID: String) -> Data?
    func write(_ data: Data, account: String, macID: String)
    func removeAll()
}

/// The stored form of a page (the list's own types stay free of Codable).
private struct StoredPage: Codable {
    struct Chat: Codable {
        var id: String
        var title: String?
        var harness: String
        var cwd: String
        var status: String
        var updatedAt: Double?
        var archived: Bool
        var lastPrompt: String?
    }

    var chats: [Chat]
    var nextCursor: String?

    init(_ page: AgentChatPage) {
        chats = page.chats.map {
            Chat(id: $0.id, title: $0.title, harness: $0.harness, cwd: $0.cwd, status: $0.status,
                 updatedAt: $0.updatedAt?.timeIntervalSince1970, archived: $0.archived,
                 lastPrompt: $0.lastPrompt)
        }
        nextCursor = page.nextCursor
    }

    var page: AgentChatPage {
        AgentChatPage(chats: chats.map {
            AgentChatListing(id: $0.id, title: $0.title, harness: $0.harness, cwd: $0.cwd, status: $0.status,
                             updatedAt: $0.updatedAt.map(Date.init(timeIntervalSince1970:)), archived: $0.archived,
                             lastPrompt: $0.lastPrompt)
        }, nextCursor: nextCursor)
    }
}

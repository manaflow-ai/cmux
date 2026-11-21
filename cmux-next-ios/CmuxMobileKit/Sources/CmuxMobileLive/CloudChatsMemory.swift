#if os(iOS)
import CmuxMobileAgentChat
import Foundation

/// The Cloud chats screens as this run last read them: each Mac's Cloud machines and each Cloud
/// machine's chat list, so the sheet opened again draws them at once and reconciles in place,
/// instead of "Loading Cloud chats…" and "Connecting to <machine> through <Mac>…" on every open.
/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster/percievably load faster". Memory only (as ``AgentChatsMemory``), bounded, the most
/// recently kept stay; sign-out forgets it (``removeAll()``).
@MainActor
public final class CloudChatsMemory {
    public static let shared = CloudChatsMemory()

    /// Macs and Cloud machines remembered (each kind on its own).
    public let limit: Int
    /// Chats kept per Cloud machine: the list's first page.
    public let chatLimit: Int
    private var machines: [String: [CloudChatMachine]] = [:]
    private var machineOrder: [String] = []
    private var chats: [String: [AcpmuxSession]] = [:]
    private var chatOrder: [String] = []
    /// Bumps on ``removeAll()``. A store names the generation its read began in, so a read that
    /// began before a sign-out never lands after it (the next account never sees this one's list).
    public private(set) var generation = 0

    public init(limit: Int = 8, chatLimit: Int = CloudChatList.pageSize) {
        self.limit = limit
        self.chatLimit = chatLimit
    }

    /// The Cloud machines last listed through `macID` (nil: none read this run).
    public func machines(on macID: String) -> [CloudChatMachine]? { machines[macID] }

    /// Keeps the Cloud machines just listed through `macID` by a read begun in `generation`
    /// (``generation`` read before the request). False, and nothing kept, when a sign-out came between.
    @discardableResult
    public func keep(machines list: [CloudChatMachine], on macID: String, readIn generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        machines[macID] = list
        Self.touch(macID, in: &machineOrder)
        while machineOrder.count > limit { machines[machineOrder.removeFirst()] = nil }
        return true
    }

    /// The chats last listed on the Cloud machine at `location` (nil: none read this run).
    public func chats(at location: CloudChatLocation) -> [AcpmuxSession]? { chats[location.id] }

    /// Keeps the newest ``chatLimit`` of the chats the Cloud machine at `location` lists now, read
    /// through a channel opened in `generation`. False, and nothing kept, when a sign-out came between.
    @discardableResult
    public func keep(chats sessions: some Collection<AcpmuxSession>, at location: CloudChatLocation,
                     readIn generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        chats[location.id] = CloudChatList.newest(sessions, shown: chatLimit).rows
        Self.touch(location.id, in: &chatOrder)
        while chatOrder.count > limit { chats[chatOrder.removeFirst()] = nil }
        return true
    }

    /// Sign-out: no Cloud machine or chat of the account stays.
    public func removeAll() {
        machines = [:]
        machineOrder = []
        chats = [:]
        chatOrder = []
        generation += 1
    }

    private static func touch(_ key: String, in order: inout [String]) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

#if DEBUG
extension CloudChatsMemory {
    /// Fixed chats kept for `location`, newest first, as a machine's list once read: the gallery's
    /// read-back of a machine opened again (`-cmux-mobile-recovery-gallery cloudkept`).
    public func keepGalleryChats(at location: CloudChatLocation) {
        let now = Date.now.timeIntervalSince1970 * 1000
        let chats: [(name: String, harness: String, prompt: String)] = [
            ("Fix the flaky login test", "claude", "The retry still races the token refresh"),
            ("Release notes for 1.4", "codex", "Draft the changelog from the merged PRs"),
            ("Profile the cold start", "claude", "Where do the first 800 ms go?"),
        ]
        let sessions = chats.enumerated().compactMap { index, chat in
            AcpmuxSession(.object([
                "sessionId": .string("gallery-\(index)"), "name": .string(chat.name), "harness": .string(chat.harness),
                "lastPrompt": .string(chat.prompt), "updatedAt": .number(now - Double(index) * 60_000),
            ]))
        }
        keep(chats: sessions, at: location, readIn: generation)
    }
}
#endif
#endif

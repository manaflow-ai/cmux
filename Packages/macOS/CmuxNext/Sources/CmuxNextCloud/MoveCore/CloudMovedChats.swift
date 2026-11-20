public import Foundation

/// The chats Move to Cloud (``CloudMove``) moved from this Mac, by their tab record on the machine (its `registry:`
/// host and the chat's session): where each came from, so Bring Back Local merges into the same folder and its menu
/// row shows only for them; and the copies a start made, waiting for their session. Kept in the user defaults
/// ``CloudMoveSetup/ledger`` names, in memory without them (tests). Rust reads and changes both ledgers
/// (`moves::ledger::MovedChats`, op `cloud_move_moved_chats`).
@MainActor
public final class CloudMovedChats {
    /// One moved chat.
    public struct Entry: Codable, Equatable, Sendable {
        public var machineID: String
        /// The tab record's host on the machine (`registry:<store>`).
        public var host: String
        /// The chat's session on the machine.
        public var session: String
        public var harness: String?
        /// The synced folder on this Mac (``CloudMoveFolder/root``) and the chat's folder in it.
        public var localRoot: String
        public var localChat: String
        /// The synced folder on the machine and the chat's folder in it.
        public var remoteFolder: String
        public var remoteChat: String
        /// The workspace name the chat had on this Mac.
        public var name: String?
        /// Set once Bring Back Local moved the chat back, kept until that tab opened.
        public var broughtBack: BroughtBack?

        public init(machineID: String, host: String, session: String, harness: String? = nil, localRoot: String, localChat: String,
                    remoteFolder: String, remoteChat: String, name: String? = nil, broughtBack: BroughtBack? = nil) {
            (self.machineID, self.host, self.session, self.harness, self.localRoot) = (machineID, host, session, harness, localRoot)
            (self.localChat, self.remoteFolder, self.remoteChat, self.name, self.broughtBack) = (localChat, remoteFolder, remoteChat, name, broughtBack)
        }

        /// What opens the chat locally after a committed bring-back, including its retry key.
        public func shown(_ back: BroughtBack) -> CloudMoveRetries.Shown {
            CloudMoveRetries.Shown(session: back.session, harness: harness, machineID: machineID, folder: localChat,
                                   name: name, key: back.key, host: host, movedSession: session)
        }
    }

    /// A chat moved back to this Mac whose tab here may not have opened yet.
    public struct BroughtBack: Codable, Equatable, Sendable {
        public var session: String
        public var key: String

        public init(session: String, key: String) {
            self.session = session
            self.key = key
        }
    }

    /// The app's ledger, for menus built where no ``AppServices`` reaches (the chat page menu).
    public static weak var app: CloudMovedChats?

    /// Where the ledger is kept (``CloudMoveSetup/ledger``); nil keeps it in memory.
    public var defaults: @MainActor () -> UserDefaults? = { nil }
    private var memory: [String: String] = [:]
    public static let defaultsKey = "cmux.cloud.movedChats"
    private static let startingKey = "cmux.cloud.startingChats"

    public init() {}

    private struct Request: Encodable {
        var moved: String?, starting: String?, action: String, host: String, session: String, remoteChat: String?, harness: String?, entry: Entry?
    }

    private struct Reply: Decodable {
        struct Stored: Decodable { var value: String? }
        struct Write: Decodable { var moved: Stored?, starting: Stored? }
        var entry: Entry?, entries: [Entry]?, started: Bool?, write: Write?
    }

    private func read(_ key: String) -> String? {
        guard let defaults = defaults() else { return memory[key] }
        return defaults.data(forKey: key).map { String(decoding: $0, as: UTF8.self) }
    }

    private func write(_ key: String, _ stored: Reply.Stored?) {
        guard let stored else { return }
        guard let defaults = defaults() else { return memory[key] = stored.value }
        if let value = stored.value { defaults.set(Data(value.utf8), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    @discardableResult
    private func ask(_ action: String, host: String = "", session: String = "", remoteChat: String? = nil, harness: String? = nil,
                     entry: Entry? = nil) -> Reply? {
        let request = Request(moved: read(Self.defaultsKey), starting: read(Self.startingKey), action: action, host: host, session: session,
                              remoteChat: remoteChat, harness: harness, entry: entry)
        let reply = CloudMoveCore().call("moved_chats", request, as: Reply.self)
        // Recorded first: a crash between these writes can replay a start's completion harmlessly.
        write(Self.defaultsKey, reply?.write?.moved)
        write(Self.startingKey, reply?.write?.starting)
        return reply
    }

    public func entry(host: String, session: String) -> Entry? { ask("entry", host: host, session: session)?.entry }

    /// Every moved chat, in no order.
    public func all() -> [Entry] { ask("all")?.entries ?? [] }

    public func record(_ entry: Entry) { ask("record", entry: entry) }

    /// Keeps a committed copy until the opened tab's first send creates its session. Pending copies never appear in
    /// menus or access triage. A relaunch can finish the same first send.
    public func copied(_ entry: Entry) { ask("copied", entry: entry) }

    /// Completes a Cloud start with the session its daemon actually created. Returns whether a copy was recorded, so
    /// its caller can start local access triage. Ordinary remote chats and no-project starts have no copy.
    @discardableResult
    public func started(host: String, session: String, remoteChat: String?, harness: String?) -> Bool {
        ask("started", host: host, session: session, remoteChat: remoteChat, harness: harness)?.started ?? false
    }

    public func forget(host: String, session: String) { ask("forget", host: host, session: session) }
}

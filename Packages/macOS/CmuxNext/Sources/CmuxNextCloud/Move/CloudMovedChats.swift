public import Foundation

/// The chats Move to Cloud (``CloudMove``) moved from this Mac, by their tab record on the
/// machine (its `registry:` host and the chat's session): where each came from, so Bring Back
/// Local (``CloudBringBack``) merges into the same folder and its menu row shows only for them.
/// Kept in the user defaults ``CloudMoveSetup/ledger`` names (the app's own), in memory only
/// without them (tests).
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
        /// Set once Bring Back Local moved the chat back: its session on this Mac and the key that
        /// makes its tab's creation idempotent. Kept until that tab opened, so the machine tab's
        /// row (and a relaunch) still only opens it.
        public var broughtBack: BroughtBack?

        public init(machineID: String, host: String, session: String, harness: String? = nil, localRoot: String, localChat: String,
                    remoteFolder: String, remoteChat: String, name: String? = nil, broughtBack: BroughtBack? = nil) {
            self.machineID = machineID
            self.host = host
            self.session = session
            self.harness = harness
            self.localRoot = localRoot
            self.localChat = localChat
            self.remoteFolder = remoteFolder
            self.remoteChat = remoteChat
            self.name = name
            self.broughtBack = broughtBack
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
    private var memory: [String: Entry] = [:]
    public static let defaultsKey = "cmux.cloud.movedChats"

    public init() {}

    public func entry(host: String, session: String) -> Entry? {
        entries()[Self.key(host, session)]
    }

    /// Every moved chat, in no order.
    public func all() -> [Entry] { Array(entries().values) }

    public func record(_ entry: Entry) {
        var all = entries()
        all[Self.key(entry.host, entry.session)] = entry
        save(all)
    }

    public func forget(host: String, session: String) {
        var all = entries()
        guard all.removeValue(forKey: Self.key(host, session)) != nil else { return }
        save(all)
    }

    private static func key(_ host: String, _ session: String) -> String { host + "\n" + session }

    private func entries() -> [String: Entry] {
        guard let defaults = defaults() else { return memory }
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        // One by one: an entry this version can't read drops alone, never the whole ledger.
        let read = (try? JSONDecoder().decode([String: Lenient].self, from: data)) ?? [:]
        return read.compactMapValues(\.entry)
    }

    /// An entry, or nil when it doesn't decode.
    private struct Lenient: Decodable {
        let entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }

    private func save(_ entries: [String: Entry]) {
        guard let defaults = defaults() else {
            memory = entries
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

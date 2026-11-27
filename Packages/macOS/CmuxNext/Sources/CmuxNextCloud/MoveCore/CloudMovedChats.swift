public import CmuxNextDaemon
public import Foundation
import CmuxNextWakeups
import Observation

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

/// The chats moving to another machine now (Move to Cloud, Move to Another Machine, Bring Back Local), for the
/// sidebar: the chat's row goes to the machine the moment the move starts, says the step and fills its bar as
/// ``CloudMoveProgress`` goes, and leaves when the chat's own row is there (Leo, 2026-11-19: a visible move
/// between machines). Every entrypoint of a move shows it (a sidebar drop, Move to…, the palette, the CLI).
/// Keyed by the chat's tab id. Rust decides each move's next state (`moves::chat_moves`, op
/// `cloud_move_chat_move`); here the app keeps the map, hooks the run's progress and waits for a landed row's
/// workspace to leave.
@MainActor
@Observable
public final class ChatMoves {
    /// One chat's move (`moves::chat_moves::Move`).
    public struct Move: Codable, Equatable, Sendable {
        /// The workspace row the chat moves out of.
        public var workspace: String?
        /// The chat is that workspace's only tab: the row itself travels. Else it stays and only shows the move.
        public var travels = false
        /// The machine it moves to (a daemon's machine id), once known.
        public var machine: String?
        /// The step and about how long is left.
        public var line: String?
        /// How far the move is, 0...1, never lower than it showed; nil until the first line.
        public var fraction: Double?
        /// The move is done and the row waits on its machine for the workspace it left to close.
        public var landed = false

        public init(workspace: String? = nil, travels: Bool = false, machine: String? = nil) {
            (self.workspace, self.travels, self.machine) = (workspace, travels, machine)
        }
    }

    /// What happened to a move (`moves::chat_moves::Event`).
    private struct Event: Encodable {
        var kind: String
        var workspace: String?, travels: Bool?, machine: String?, line: String?, fraction: Double?
    }

    /// The longest a moved row waits on its machine for the workspace it left to close.
    public static let landing: Duration = .seconds(10)

    public private(set) var all: [String: Move] = [:]
    /// The store each move's chat moves out of, for ``landed(tab:)``.
    @ObservationIgnored private var stores: [String: DaemonStore] = [:]
    /// Each landed move's wait for its workspace to leave.
    @ObservationIgnored private var landings: [String: Task<Void, Never>] = [:]

    public init() {}

    /// A move of tab `tab` starts (or its sidebar drop already started it: what that knew stays).
    public func begin(tab: String, workspace: String?, travels: Bool, machine: String?, store: DaemonStore? = nil) {
        if let store { stores[tab] = store }
        apply(tab, Event(kind: "begin", workspace: workspace, travels: travels, machine: machine))
    }

    /// The move of `tab` goes to `machine` (Move to Cloud picks or makes one after it starts).
    public func reach(tab: String, machine: String) { apply(tab, Event(kind: "reach", machine: machine)) }

    /// The move of `tab` shows `line`, `fraction` of the way.
    public func show(tab: String, line: String, fraction: Double?) { apply(tab, Event(kind: "show", line: line, fraction: fraction)) }

    /// The move of `tab` is done: a travelled row stays on its machine until the store it moved out of no longer
    /// lists the workspace it left (the chat's own row is there by then), at most ``landing``, so it never slides
    /// back first.
    public func landed(tab: String) {
        apply(tab, Event(kind: "landed"))
        guard let move = all[tab], move.landed, let workspace = move.workspace, let store = stores[tab] else { return }
        let deadline = ObservationDeadline(owner: "chat-move-landing")
        // task-owner: this landing's wait, kept in `landings` and cancelled when the move goes; it ends when the workspace leaves or at `landing`
        landings[tab] = Task { @MainActor [weak self] in
            await deadline.until({ store.workspace(id: workspace) == nil }, limit: Self.landing)
            if self?.all[tab]?.landed == true { self?.apply(tab, Event(kind: "left")) }
        }
    }

    /// The move's run of `tab` ended, done or not. A landed row stays until its workspace leaves.
    public func end(tab: String) { apply(tab, Event(kind: "end")) }

    private func apply(_ tab: String, _ event: Event) {
        struct Request: Encodable { var prior: Move?, event: Event }
        struct Reply: Decodable { var next: Move? }
        let prior = all[tab]
        guard prior != nil || event.kind == "begin" else { return }
        let next = CloudMoveCore().call("chat_move", Request(prior: prior, event: event), as: Reply.self)?.next
        if next != prior { all[tab] = next }
        guard next == nil else { return }
        stores[tab] = nil
        landings.removeValue(forKey: tab)?.cancel()
    }
}

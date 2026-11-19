public import CmuxNextDaemon
public import Foundation
import CmuxNextWakeups
import Observation

/// The chats moving to another machine now (Move to Cloud, Move to Another Machine, Bring Back Local), for the
/// sidebar: the chat's row goes to the machine it moves to the moment the move starts, says the step and fills its
/// bar as Rust's ``CloudMoveProgress`` line goes, and leaves when the chat's own row is there (Leo, 2026-11-19:
/// a visible move between machines). Every entrypoint of a move shows it (a sidebar drop, Move to…, the palette,
/// the CLI); the drop only starts it sooner, with the machine already known. Keyed by the chat's tab id.
@MainActor
@Observable
public final class ChatMoves {
    public struct Move: Equatable, Sendable {
        /// The workspace row the chat moves out of.
        public var workspace: String?
        /// The chat is the workspace's only tab: the row itself travels to the machine. Else it stays where it is
        /// (the other tabs stay) and only shows the move.
        public var travels = false
        /// The machine it moves to (a daemon's machine id: `local` for this Mac), once known.
        public var machine: String?
        /// The step and about how long is left (``CloudMoveProgress``).
        public var line: String?
        /// How far the move is, 0...1, never lower than it showed; nil until the first line.
        public var fraction: Double?
        /// The move is done and the row waits on its machine for the workspace it left to close (``landed(tab:)``).
        public var landed = false
    }

    public private(set) var all: [String: Move] = [:]
    /// The store each move's chat moves out of, for ``landed(tab:)``.
    @ObservationIgnored private var stores: [String: DaemonStore] = [:]
    /// Each landed move's wait for its workspace to leave.
    @ObservationIgnored private var landings: [String: Task<Void, Never>] = [:]

    public init() {}

    /// A move of tab `tab` starts (or its sidebar drop already started it: what that knew stays).
    public func begin(tab: String, workspace: String?, travels: Bool, machine: String?, store: DaemonStore? = nil) {
        if let store { stores[tab] = store }
        var move = all[tab].flatMap { $0.landed ? nil : $0 } ?? Move()
        if move.workspace == nil, let workspace { (move.workspace, move.travels) = (workspace, travels) }
        move.machine = machine ?? move.machine
        all[tab] = move
    }

    /// A run starts moving chat tab `tab` of `store` to `machine` (nil: not known yet; ``reach(tab:machine:)``):
    /// `progress`'s lines go on its row. The run calls ``landed(tab:)`` when it moved; its `progress.end()` ends it, done or not.
    public func begin(_ tab: TabModel, of store: DaemonStore, to machine: String?, progress: CloudMoveProgress) {
        let workspace = store.workspace(holdingTab: tab.id), tabID = tab.id
        begin(tab: tabID, workspace: workspace?.id, travels: workspace.map { $0.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 } ?? false,
              machine: machine, store: store)
        progress.stepped = { [weak self] line, fraction in self?.show(tab: tabID, line: line, fraction: fraction) }
        progress.ended = { [weak self] in self?.end(tab: tabID) }
    }

    /// The move of `tab` goes to `machine` (Move to Cloud picks or makes one after it starts).
    public func reach(tab: String, machine: String) {
        guard all[tab] != nil, all[tab]?.machine != machine else { return }
        all[tab]?.machine = machine
    }

    /// The move of `tab` shows `line`, `fraction` of the way.
    public func show(tab: String, line: String, fraction: Double?) {
        guard var move = all[tab] else { return }
        move.line = line
        if let fraction { move.fraction = max(move.fraction ?? 0, min(max(fraction, 0), 1)) }
        if move != all[tab] { all[tab] = move }
    }

    /// The longest a moved row waits on its machine for the source workspace to close.
    public static let landing: Duration = .seconds(10)

    /// The move of `tab` is done: a travelled row stays on its machine until the store it moved out of no longer
    /// lists the workspace it left (the chat's own row is there by then), at most ``landing``, so it never slides
    /// back first. A row that stayed put is the chat's own again at once.
    public func landed(tab: String) {
        guard let move = all[tab], move.travels, let workspace = move.workspace, let store = stores[tab] else { return end(tab: tab) }
        all[tab]?.landed = true
        let deadline = ObservationDeadline(owner: "chat-move-landing")
        // task-owner: this landing's wait, kept in `landings` and cancelled by `drop`; it ends when the workspace leaves or at `landing`
        landings[tab] = Task { @MainActor [weak self] in
            await deadline.until({ store.workspace(id: workspace) == nil }, limit: Self.landing)
            if self?.all[tab]?.landed == true { self?.drop(tab) }
        }
    }

    /// The move's run of `tab` ended. Not moved (failed or stopped): its row is the chat's own again, back where it
    /// was. A landed row stays until its workspace leaves (``landed(tab:)``).
    public func end(tab: String) {
        if all[tab]?.landed != true { drop(tab) }
    }

    private func drop(_ tab: String) {
        all[tab] = nil
        stores[tab] = nil
        landings.removeValue(forKey: tab)?.cancel()
    }
}

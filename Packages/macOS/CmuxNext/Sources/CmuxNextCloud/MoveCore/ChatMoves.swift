public import CmuxNextDaemon
public import Foundation
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
    }

    public private(set) var all: [String: Move] = [:]

    public init() {}

    /// A move of tab `tab` starts (or its sidebar drop already started it: what that knew stays).
    public func begin(tab: String, workspace: String?, travels: Bool, machine: String?) {
        var move = all[tab] ?? Move()
        if move.workspace == nil, let workspace { (move.workspace, move.travels) = (workspace, travels) }
        move.machine = machine ?? move.machine
        all[tab] = move
    }

    /// A run starts moving chat tab `tab` of `store` to `machine` (nil: not known yet; ``reach(tab:machine:)``):
    /// `progress`'s lines go on its row. The run calls ``end(tab:)`` when it ends, done or not.
    public func begin(_ tab: TabModel, of store: DaemonStore, to machine: String?, progress: CloudMoveProgress) {
        let workspace = store.workspace(holdingTab: tab.id), tabID = tab.id
        begin(tab: tabID, workspace: workspace?.id, travels: workspace.map { $0.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 } ?? false,
              machine: machine)
        progress.stepped = { [weak self] line, fraction in self?.show(tab: tabID, line: line, fraction: fraction) }
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

    /// The move of `tab` ended, done or not: its row is the chat's own again (moved, or back where it was).
    public func end(tab: String) {
        all[tab] = nil
    }
}

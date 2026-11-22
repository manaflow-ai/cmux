import CmuxNextAgentPane
import Foundation

/// The agent-home folders of closed workspaces (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE, amendment
/// (a)). cmux-next has no explicit workspace delete and a History reopen gets a new workspace id,
/// so a close (window close, app quit, workspace close) never deletes a folder: chat files may be
/// in it. A reopen from History moves the folder to the new id; an expired History entry sends
/// it to the Trash, never a hard delete. A symlink at the path is never moved or trashed.
@MainActor
final class AgentHomeHistory {
    private let home: AgentHome?
    private let trash: @Sendable (URL) throws -> Void
    /// Where the Trash work runs: off the main thread in the app, inline in tests.
    private let run: (@escaping @Sendable () -> Void) -> Void

    init(home: AgentHome? = .standard,
         trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         run: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
             // task-owner: one Trash move per expired folder; nothing waits for it
             Task.detached(priority: .utility) { work() }
         }) {
        self.home = home
        self.trash = trash
        self.run = run
    }

    /// A History reopen gave workspace `old` the id `new`: its folder follows, before the new
    /// workspace's first chat. One rename on the main thread; false when there was nothing to move
    /// or the move was refused (the new workspace then gets a fresh folder on first use).
    @discardableResult
    func reopened(from old: String?, to new: String) -> Bool {
        guard let home, let old else { return false }
        return home.move(from: old, to: new)
    }

    /// These workspaces' History entries expired: their folders go to the Trash.
    func expired(_ ids: [String]) {
        guard let home else { return }
        let trash = trash
        for id in ids {
            run { _ = home.trash(id, using: trash) }
        }
    }
}

import CmuxNextDaemon
import Foundation

/// Which conversation Home's Chief tab shows (G6, brains/DESIGN-cmux-lawrence.md
/// section 6): the main conversation of the chief placed on a paired server
/// (a cloud conversation, answered by that server's brain) when the signed-in
/// user has one, else the local conversation with the local mux.
@MainActor
enum HomeChiefSource {
    /// The Chief tab's conversation: the placed chief's main conversation, else `local`.
    nonisolated static func choose(local: String?, localHasHistory: Bool = false, placed: CloudChief?) -> String? {
        placed?.mainConversation ?? local
    }

    /// The Chief moved to `chief` (placed on a server) from `local`: the tabs
    /// that still show the local Chief close, and the moved Chief opens in the
    /// first one's pane, so Home keeps one Chief tab. Nothing moves while the
    /// Chief is local or the moved Chief already has its tab.
    static func move(local: String?, chief: String, in workspaces: [WorkspaceModel]) -> (close: [SurfaceID], pane: PaneID?) {
        guard let local, local != chief, !HomeChiefTabKey.isOpen(chief: chief, in: workspaces) else { return ([], nil) }
        var close: [SurfaceID] = []
        var pane: PaneID?
        for candidate in workspaces.flatMap(\.screens).flatMap(\.panes) {
            for tab in candidate.tabs where tab.kind == .conversation && tab.snapshot.conversation?.conversation == local {
                close.append(tab.surface)
                pane = pane ?? candidate.handle
            }
        }
        return (close, pane)
    }

    /// The tabs that show a placed chief's conversation while the Chief is
    /// another one (red-test stub).
    static func staleChiefTabs(placed: String?, chief: String, in workspaces: [WorkspaceModel]) -> [SurfaceID] { [] }

    /// The placed chief (`CloudChiefs.placed`) with a main conversation, or
    /// nil: signed out, no chief placed, or the read failed (Home then keeps
    /// the local chief; a failure is logged by the caller, never shown).
    static func readPlaced(call: CloudChiefs.Call) async throws -> CloudChief? {
        guard let chief = CloudChiefs.placed(in: try await CloudChiefs.list(call: call)), chief.mainConversation != nil else { return nil }
        return chief
    }
}

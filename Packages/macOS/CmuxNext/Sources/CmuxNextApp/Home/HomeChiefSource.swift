import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation

/// Which conversation Home's Chief tab shows: the main conversation of the
/// signed-in user's cloud Chief (the Hosted Chief by default, or "Chief (Mac
/// mini)" when the user switched to it; `HomeCloudChiefs`), else the local
/// conversation with the local mux.
@MainActor
enum HomeChiefSource {
    /// The Chief tab's conversation: the shown cloud Chief's main conversation, else `local`.
    /// One history: with a Hosted Chief the local Chief's history is copied
    /// into its main conversation (`HomeService+HostedChief`), so a cloud
    /// Chief takes the tab also when the local Chief has history. Without
    /// one (a service with no Cloud Chief brains), a placed chief takes the
    /// tab only when the local Chief has no history to hide.
    nonisolated static func choose(local: String?, localHasHistory: Bool, cloud: HomeCloudChiefs, choice: HomeChiefChoice) -> String? {
        if cloud.hosted == nil, let local, localHasHistory { return local }
        return cloud.shown(choice: choice)?.mainConversation ?? local
    }

    /// The Chief moved to `chief` (a cloud Chief) from one of `from` (the
    /// local Chief, or the other cloud Chief after a switch): the tabs that
    /// still show one of them close, and the Chief opens in the first one's
    /// pane, so Home keeps one Chief tab. Nothing moves while the Chief is
    /// local or it already has its tab.
    static func move(from: [String], chief: String, in workspaces: [WorkspaceModel]) -> (close: [SurfaceID], pane: PaneID?) {
        let from = Set(from.filter { $0 != chief })
        guard !from.isEmpty, !HomeChiefTabKey.isOpen(chief: chief, in: workspaces) else { return ([], nil) }
        var close: [SurfaceID] = []
        var pane: PaneID?
        for candidate in workspaces.flatMap(\.screens).flatMap(\.panes) {
            for tab in candidate.tabs where tab.kind == .conversation && tab.snapshot.conversation?.conversation.map(from.contains) == true {
                close.append(tab.surface)
                pane = pane ?? candidate.handle
            }
        }
        return (close, pane)
    }

    /// The tabs that show another cloud Chief's conversation (`stale`)
    /// while the Chief is `chief`: a switch or a relaunch gives the tab back.
    static func staleChiefTabs(stale: [String], chief: String, in workspaces: [WorkspaceModel]) -> [SurfaceID] {
        let stale = Set(stale.filter { $0 != chief })
        guard !stale.isEmpty else { return [] }
        return workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            .filter { $0.kind == .conversation && $0.snapshot.conversation?.conversation.map(stale.contains) == true }
            .map(\.surface)
    }

    /// The user's cloud Chiefs, with a Hosted Chief made when this service
    /// runs Cloud Chief brains (`hostedBrains`); without them only the
    /// placed chief is read (Home then keeps the local chief when none is
    /// placed). A failure is logged by the caller, never shown.
    static func readCloud(call: CloudChiefs.Call, hostedBrains: Bool) async throws -> HomeCloudChiefs {
        if hostedBrains { return try await CloudChiefs.ensureHosted(call: call) }
        let placed = CloudChiefs.placed(in: try await CloudChiefs.list(call: call))
        return HomeCloudChiefs(hosted: nil, placed: placed?.mainConversation == nil ? nil : placed)
    }
}

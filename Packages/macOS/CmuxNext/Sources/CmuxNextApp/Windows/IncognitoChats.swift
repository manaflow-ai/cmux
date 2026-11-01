import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import os

/// Agent chats of incognito workspaces. An incognito space keeps no history, is never restored and is
/// deleted when its window closes (leo-workspace design/spaces.md "Incognito"; Leo, 2026-10-31: "like
/// incognito spaces, each new window is a space"). A chat started in one is an ordinary acpmux chat,
/// so when the workspace closes (its window, Delete Space, quit) acpmux stops and deletes every chat
/// it recorded for that workspace, and the transcripts they wrote: none lists under Earlier, in the
/// palette or on New Tab after. acpmux owns which chats those are; the app only names the workspace.
@MainActor
enum IncognitoChats {
    /// Purges not answered yet; the quit waits for them before acpmux's agents end.
    private static var pending: [UUID: Task<Void, Never>] = [:]

    /// `WorkspaceClose.willClose`: every close path tells it before it closes `workspace`.
    static func closing(_ workspace: WorkspaceModel, _ services: AppServices) {
        guard let key = key(of: workspace.id, key: workspace.key?.rawValue, incognito: services.windows.isIncognito(workspace:)),
              let acpmux = QuitAgents.environment(services) else { return }
        let id = UUID()
        // task-owner: this enum until acpmux answers (or its deadline); the quit drains it.
        pending[id] = Task { @MainActor in
            defer { pending[id] = nil }
            do {
                try await acpmux.purgeWorkspace(key: key)
            } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "incognito")
                    .error("incognito chats purge failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The acpmux workspace key whose chats go when workspace `id` closes: its key when it is
    /// incognito, else nil (a normal workspace's chats stay in history).
    static func key(of id: String, key: String?, incognito: (String) -> Bool) -> String? {
        guard let key, !key.isEmpty, incognito(id) else { return nil }
        return key
    }

    /// Quit: the purges of the incognito workspaces just closed reach acpmux before its agents end.
    static func drain() async {
        for task in pending.values { await task.value }
    }
}

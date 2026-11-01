import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService

// Share with Guest (design chat-multiplayer.md 6): one-line forwards to the App's owners.
extension AppServices: AgentShareHost {
    func shareTab(surface: SurfaceID) -> TabModel? { locateTab(surface: surface) }
    func shareTab(id: String) -> TabModel? { locateTab(id)?.0 }
    func shareTabID(showing session: String) -> String? { agentTabs.tab(showing: session) }
    var shareFocusedTabID: String? { windows.active?.focusedPane?.stripModel.selectedID?.rawValue }
    func shareConnection(holding tab: TabModel) -> DaemonConnection? { locateTab(tab.id).map(\.1).map(daemon(for:))?.connection }
    func shareIsOnThisMac(_ tab: TabModel) -> Bool { machines.local.store.tab(idOrResource: tab.id) === tab }
    var shareLocalConnection: DaemonConnection? { machines.local.connection }
    func shareOwnerToken() async -> String? { try? await cloud.installIdentity.installToken() }
    func shareCopy(_ text: String) { AppActionContext(services: self).copy(text) }
    func shareNotice(_ message: String) { BrowserFileImport.toast(self, id: "agent-share", message) }
}

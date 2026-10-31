import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar

// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): one-line forwards to the App's owners.
extension AppServices: AutoArchiveHost {
    func autoArchiveCandidates() -> [AutoArchivePlanner.Candidate] { AutoArchiveCandidates(stores: machines.daemons.map(\.store), title: shownWorkspaceName).candidates(placed: SidebarDocStore.current?.shown?.items ?? [:]) }
    func autoArchiveShownWorkspaces() -> Set<String> { Set(windows.controllers.compactMap(\.state.workspaceID)) }
    func autoArchivePolicy() -> AutoArchivePolicy { AutoArchivePolicy(styleName: settings?.snapshot.autoArchive.style.rawValue, idleDays: settings?.snapshot.autoArchive.idleDays) }
    func autoArchiveAsk(_ card: SidebarNoticeCard) async -> String? { await machineAsks.choose(card) }
    func autoArchiveSetStyle(_ style: AutoArchivePolicy.Style) async { try? await settings?.setAutoArchiveStyle(named: style.rawValue) }
    func autoArchiveItem(workspace id: String) -> String? { SidebarDocWiring.item(workspace: id, machines) }
    func autoArchiveToast(_ message: String, undo: @escaping @MainActor () -> Void) { CmuxToastCenter.shared.showUndo(message, id: "auto-archive", in: windows.active?.window ?? NSApp?.mainWindow, undo: undo) }
}

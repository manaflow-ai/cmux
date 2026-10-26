import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar

// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): one-line forwards to the App's owners.
extension AppServices: AutoArchiveHost {
    func autoArchiveCandidates() -> [AutoArchivePlanner.Candidate] {
        AutoArchiveCandidates(stores: { [weak self] in self?.machines.daemons.map(\.store) ?? [] }, title: { [weak self] in self?.shownWorkspaceName($0) ?? $0.displayName })
            .candidates(placed: SidebarDocStore.current?.shown?.items ?? [:])
    }
    func autoArchiveShownWorkspaces() -> Set<String> { Set(windows.controllers.compactMap(\.state.workspaceID)) }
    func autoArchivePolicy() -> AutoArchivePolicy { AutoArchivePolicy(settings?.snapshot.autoArchive) }
    func autoArchiveAsk(_ card: SidebarNoticeCard) async -> Bool { await machineAsks.ask(card) }
    func autoArchiveItem(workspace id: String) -> String? { SidebarDocWiring.item(workspace: id, machines) }
    func autoArchiveToast(_ message: String, undo: @escaping @MainActor () -> Void) {
        guard let window = windows.active?.window ?? NSApp.mainWindow else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "auto-archive", message: message, action: .undo(), duration: .seconds(10)), in: window).onAction = { undo() }
    }
}

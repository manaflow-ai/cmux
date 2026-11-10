import CmuxNextAgentActivity
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// Opens a workspace row's Try pill (``SidebarTryPillView``): shows that workspace, then opens what
/// its agent finished in it: a page in a new browser tab (a Tag Opener address,
/// `http://127.0.0.1:17320/<tag>`, launches its build), or a command in a new terminal, run. A
/// pill click is the person's own gesture, so it may change their view. Aziz, 2026-11-09:
/// "whenever a workspace agent finished its task, theres a direct way for me to try out and verify
/// its work in addition to the artifact."
@MainActor
struct SidebarTryOpener {
    let services: AppServices

    /// Shows the pill's own workspace (its window takes it now, I6), then opens the Try in a pane of
    /// that workspace, never the one the person looked at before the click. A pane not mounted yet
    /// is waited for, as the provider sign-in tab does (`AppServices+LoginTabs.swift`).
    func open(_ workspace: WorkspaceID, _ tryIt: SidebarTry) {
        let id = workspace.rawValue
        guard let window = services.windows.reveal(workspaceID: id) else { return }
        services.windows.show(workspaceID: id, in: window.state, from: .thisWindow)
        let mounted: @MainActor @Sendable () -> Bool = { [services] in
            _ = services.paneMounts.generation
            return window.content?.workspace.id == id && window.focusedPane != nil
        }
        if mounted() { return place(tryIt, in: window, workspace: id) }
        Task { @MainActor in
            await ObservationDeadline(owner: "sidebar-try-pane").until(mounted, limit: .seconds(5))
            place(tryIt, in: window, workspace: id)
        }
    }

    private func place(_ tryIt: SidebarTry, in window: WindowController, workspace: String) {
        guard window.content?.workspace.id == workspace, let pane = window.focusedPane else { return }
        if let text = tryIt.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            _ = pane.newBrowserTab(url: url)
        } else if let command = tryIt.command, AgentLaneTry.isPlainLine(command) {
            pane.newTerminalTab(cwd: tryIt.cwd, typing: command + "\n")
        }
    }

    /// Hands the sidebar its Try opener (once, at launch).
    static func install(_ services: AppServices) {
        SidebarSessionTree.shared.onTry = { [weak services] workspace, tryIt in
            guard let services else { return }
            SidebarTryOpener(services: services).open(workspace, tryIt)
        }
    }
}

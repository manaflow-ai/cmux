import CmuxNextSidebar
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

    func open(_ workspace: WorkspaceID, _ tryIt: SidebarTry) {
        guard let window = services.windows.reveal(workspaceID: workspace.rawValue), let pane = window.focusedPane else { return }
        if let text = tryIt.url, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            _ = pane.newBrowserTab(url: url)
        } else if let command = tryIt.command, !command.contains("\n") {
            pane.newTerminalTab(typing: command + "\n")
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

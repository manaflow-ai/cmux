import SwiftUI
import AppKit
import Combine

/// The file explorer section that sits below the tab list in the sidebar.
/// This is a self-contained view that manages its own state and communicates
/// file-open requests via callbacks.
struct FileExplorerSidebarSection: View {
    @ObservedObject var explorerState: FileExplorerState
    @EnvironmentObject var tabManager: TabManager
    let height: CGFloat

    /// Publisher that emits when the focused workspace's currentDirectory changes.
    /// Re-binds when tabManager updates (workspace switch).
    private var currentDirectoryPublisher: AnyPublisher<String, Never> {
        guard let workspace = tabManager.selectedTab else {
            return Empty().eraseToAnyPublisher()
        }
        return workspace.$currentDirectory
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var body: some View {
        FileExplorerView(
            state: explorerState,
            onFileSelect: { url in
                openFileInPanel(url)
            },
            onFileDoubleClick: { url in
                openFileInExternalEditor(url)
            },
            onSyncToCwd: {
                updateRoot()
            }
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onChange(of: tabManager.selectedTabId) { _ in
            updateRoot()
        }
        .onReceive(currentDirectoryPublisher) { _ in
            updateRoot()
        }
        .onAppear {
            updateRoot()
        }
    }

    private func updateRoot() {
        guard let workspace = tabManager.selectedTab else {
            explorerState.setRoot(nil)
            return
        }
        let dirPath = workspace.currentDirectory
        guard !dirPath.isEmpty else {
            explorerState.setRoot(nil)
            return
        }
        explorerState.setRoot(URL(fileURLWithPath: dirPath))
    }

    /// Open a file as a new panel tab in the focused workspace.
    private func openFileInPanel(_ url: URL) {
        guard let workspace = tabManager.selectedTab else { return }
        let focusedPaneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let paneId = focusedPaneId else { return }
        workspace.newEditorSurface(inPane: paneId, filePath: url.path, focus: true)
    }

    /// Open a file in the user's default editor or system app.
    private func openFileInExternalEditor(_ url: URL) {
        if let editor = ProcessInfo.processInfo.environment["EDITOR"], !editor.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, url.path]
            try? process.run()
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

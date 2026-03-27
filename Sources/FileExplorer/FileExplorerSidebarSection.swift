import SwiftUI
import AppKit

/// The file explorer section that sits below the tab list in the sidebar.
struct FileExplorerSidebarSection: View {
    @ObservedObject var explorerState: FileExplorerState
    @EnvironmentObject var tabManager: TabManager
    let height: CGFloat

    /// Tracks the last directory we synced to, so we only refresh on actual changes.
    @State private var lastSyncedDirectory: String = ""

    /// Timer that polls the workspace's currentDirectory every second.
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

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
                syncToWorkingDirectory()
            }
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onChange(of: tabManager.selectedTabId) { _ in
            syncToWorkingDirectory()
        }
        .onReceive(pollTimer) { _ in
            checkForDirectoryChange()
        }
        .onAppear {
            debugLog("onAppear — file explorer visible")
            syncToWorkingDirectory()
        }
        .onDisappear {
            debugLog("onDisappear — file explorer hidden")
        }
    }

    /// Write debug info to a file so we can read it from CLI.
    private func debugLog(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/cmux-explorer-debug.log") {
                if let handle = FileHandle(forWritingAtPath: "/tmp/cmux-explorer-debug.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/cmux-explorer-debug.log", contents: data)
            }
        }
    }

    /// Force-sync the file explorer root to the workspace's current directory.
    private func syncToWorkingDirectory() {
        guard let workspace = tabManager.selectedTab else {
            debugLog("syncToWorkingDirectory: no selected workspace")
            explorerState.setRoot(nil)
            lastSyncedDirectory = ""
            return
        }
        let dirPath = workspace.currentDirectory
        debugLog("syncToWorkingDirectory: workspace.currentDirectory = '\(dirPath)'")
        guard !dirPath.isEmpty else {
            explorerState.setRoot(nil)
            lastSyncedDirectory = ""
            return
        }
        lastSyncedDirectory = dirPath
        explorerState.setRoot(URL(fileURLWithPath: dirPath))
    }

    /// Lightweight check — only updates if the directory actually changed.
    private func checkForDirectoryChange() {
        guard let workspace = tabManager.selectedTab else {
            debugLog("poll: no workspace")
            return
        }
        let currentDir = workspace.currentDirectory
        // Log every 10th poll to avoid spam, but always log changes
        if currentDir != lastSyncedDirectory {
            debugLog("poll CHANGED: '\(lastSyncedDirectory)' -> '\(currentDir)'")
        }
        guard !currentDir.isEmpty, currentDir != lastSyncedDirectory else {
            // Directory hasn't changed, but refresh git status (detects file edits)
            explorerState.refreshGitStatusOnly()
            return
        }
        lastSyncedDirectory = currentDir
        explorerState.setRoot(URL(fileURLWithPath: currentDir))
    }

    /// Single-click: open file preview in a new tab.
    private func openFileInPanel(_ url: URL) {
        guard let workspace = tabManager.selectedTab else { return }
        let focusedPaneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let paneId = focusedPaneId else { return }
        // Open in native NSTextView editor (editable, Cmd+S to save)
        workspace.newEditorSurface(inPane: paneId, filePath: url.path, focus: true)
        explorerState.currentEditingFilePath = url.path
    }

    /// Double-click: open in Sublime Text, fall back to system default.
    private func openFileInExternalEditor(_ url: URL) {
        // Try Sublime Text first
        let sublPaths = [
            "/usr/local/bin/subl",
            "/opt/homebrew/bin/subl",
            "/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl"
        ]
        for sublPath in sublPaths {
            if FileManager.default.fileExists(atPath: sublPath) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sublPath)
                process.arguments = [url.path]
                try? process.run()
                return
            }
        }
        // Fall back to $EDITOR or system default
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

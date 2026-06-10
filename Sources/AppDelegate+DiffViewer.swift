import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Diff viewer launching
extension AppDelegate {
    /// Opens the diff viewer for the focused workspace of `tabManager` by spawning the
    /// bundled `cmux diff` CLI. This is the single shared diff-open path: both the
    /// command-palette entry and the Open Diff Viewer keyboard shortcut funnel through
    /// here so neither duplicates diff-open logic. Returns `false` (caller beeps) when
    /// there is no focused workspace or the bundled CLI is missing.
    @discardableResult
    func openDiffViewerForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
#if DEBUG
        if let debugOpenDiffViewerHandler {
            debugOpenDiffViewerHandler()
            return true
        }
#endif
        guard let workspace = tabManager?.selectedWorkspace,
              let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let cwd = workspace.resolvedWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return launchDiffViewerProcess(
            cliURL: cliURL,
            socketPath: socketPath,
            cwd: cwd,
            workspaceId: workspace.id,
            surfaceId: workspace.focusedPanelId
        )
    }

    @discardableResult
    private func launchDiffViewerProcess(
        cliURL: URL,
        socketPath: String,
        cwd: String,
        workspaceId: UUID,
        surfaceId: UUID?
    ) -> Bool {
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            "diff",
            "--unstaged",
            "--cwd", cwd,
            "--workspace", workspaceId.uuidString,
            "--focus", "true",
        ]
        if let surfaceId {
            arguments.append(contentsOf: ["--surface", surfaceId.uuidString])
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        if let surfaceId {
            environment["CMUX_SURFACE_ID"] = surfaceId.uuidString
        }
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let outputCollector = ProcessOutputCollector(stdout: stdoutPipe, stderr: stderrPipe)
        outputCollector.start()
        process.terminationHandler = { terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                AppDelegate.shared?.diffViewerProcesses.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0 else { return }
#if DEBUG
                // Log only non-sensitive metadata: the child's stdout/stderr can echo
                // repo paths and file contents, so report a byte count, not the text.
                cmuxDebugLog("openDiffViewer exited status=\(terminationStatus) outputBytes=\(output.utf8.count)")
#endif
                NSSound.beep()
            }
        }

        do {
            try process.run()
            let processIdentifier = process.processIdentifier
            diffViewerProcesses[processIdentifier] = process
            if !process.isRunning {
                diffViewerProcesses.removeValue(forKey: processIdentifier)
            }
#if DEBUG
            cmuxDebugLog("openDiffViewer pid=\(process.processIdentifier)")
#endif
            return true
        } catch {
            outputCollector.cancel()
#if DEBUG
            cmuxDebugLog("openDiffViewer failed errorType=\(type(of: error))")
#endif
            return false
        }
    }

}

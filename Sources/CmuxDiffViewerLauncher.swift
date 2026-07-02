import AppKit
import CmuxSettings
import Foundation

@MainActor
final class CmuxDiffViewerLauncher {
    static let shared = CmuxDiffViewerLauncher()

    private var processes: [Int32: Process] = [:]

    private init() {}

    @discardableResult
    func start(cwd: String, workspaceId: UUID, surfaceId: UUID?) -> Bool {
        guard let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return false
        }

        let preferredSocketPath = SocketControlSettings.socketPath()
        let activeSocketPath = TerminalController.shared.activeSocketPath(preferredPath: preferredSocketPath)
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", activeSocketPath,
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
        environment["CMUX_SOCKET_PATH"] = activeSocketPath
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
                Self.shared.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0 else { return }
                // The child's stdout/stderr can contain repo paths or file contents,
                // and tagged Debug logs land under /tmp; log only a byte count.
                let outputByteCount = output.utf8.count
                #if DEBUG
                cmuxDebugLog("diffViewer.launch exited status=\(terminationStatus) outputBytes=\(outputByteCount)")
                #endif
                NSSound.beep()
            }
        }

        do {
            try process.run()
            let processIdentifier = process.processIdentifier
            processes[processIdentifier] = process
            if !process.isRunning {
                processes.removeValue(forKey: processIdentifier)
            }
            #if DEBUG
            cmuxDebugLog("diffViewer.launch pid=\(process.processIdentifier) cwd=\(cwd)")
            #endif
            return true
        } catch {
            outputCollector.cancel()
            #if DEBUG
            cmuxDebugLog("diffViewer.launch failed cwd=\(cwd) error=\(error.localizedDescription)")
            #endif
            return false
        }
    }
}

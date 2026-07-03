public import Foundation

/// Spawns the bundled `cmux diff` CLI as a detached child process and owns the
/// running-process registry so the launch lifecycle never lives on the app
/// delegate.
///
/// Lifted byte-faithfully from the legacy `AppDelegate.launchDiffViewerProcess`:
/// the `Process` construction, argument list, environment overrides (including
/// dropping `CMUX_SOCKET`), null stdin, output draining, and the
/// nonzero-exit beep are unchanged. The only inversions are the three
/// app-target couplings, each moved behind a constructor-injected seam:
/// - the running-process map `[Int32: Process]`, formerly mutated through
///   `AppDelegate.shared?.diffViewerProcesses`, now owned here;
/// - the `ProcessOutputCollector` (an app-target type shared by other
///   launchers), supplied through `makeOutputDrainer`;
/// - the `NSSound.beep()` failure cue and the DEBUG `cmuxDebugLog` lines,
///   supplied through `beep` and `debugLog`.
///
/// Isolation: `@MainActor`, because every caller is a main-thread UI flow and
/// the legacy launch ran synchronously on the main thread; the registry is
/// only mutated on launch and from the termination handler, which hops back to
/// the main actor exactly as the legacy `Task { @MainActor in … }` did.
@MainActor
public final class DiffViewerLaunchService: DiffViewerLaunching {
    private var processes: [Int32: Process] = [:]
    private let makeOutputDrainer: @Sendable (_ stdout: Pipe, _ stderr: Pipe) -> any DiffViewerProcessOutputDraining
    private let environment: @Sendable () -> [String: String]
    private let beep: @MainActor @Sendable () -> Void
    private let debugLog: @Sendable (String) -> Void

    /// Creates the service with explicit collaborators.
    ///
    /// - Parameters:
    ///   - makeOutputDrainer: Factory for a per-launch output drainer; the app
    ///     returns its `ProcessOutputCollector`, tests a recording fake.
    ///   - environment: Base environment the child inherits before the
    ///     diff-viewer overrides are applied (the app passes
    ///     `ProcessInfo.processInfo.environment`).
    ///   - beep: Failure cue played on a nonzero child exit (the app passes
    ///     `NSSound.beep`).
    ///   - debugLog: DEBUG sink for the `openDiffViewer …` trace lines (the app
    ///     passes `cmuxDebugLog` in DEBUG, a no-op otherwise).
    public init(
        makeOutputDrainer: @escaping @Sendable (_ stdout: Pipe, _ stderr: Pipe) -> any DiffViewerProcessOutputDraining,
        environment: @escaping @Sendable () -> [String: String],
        beep: @escaping @MainActor @Sendable () -> Void,
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeOutputDrainer = makeOutputDrainer
        self.environment = environment
        self.beep = beep
        self.debugLog = debugLog
    }

    @discardableResult
    public func launch(
        cliURL: URL,
        socketPath: String,
        cwd: String,
        workspaceId: UUID,
        surfaceId: UUID?,
        useLastTurnSource: Bool,
        sessionId: String?,
        focus: Bool
    ) -> Bool {
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            "diff",
            useLastTurnSource ? "--last-turn" : "--unstaged",
            "--cwd", cwd,
            "--workspace", workspaceId.uuidString,
            "--focus", focus ? "true" : "false",
        ]
        if let surfaceId {
            arguments.append(contentsOf: ["--surface", surfaceId.uuidString])
        }
        if useLastTurnSource, let sessionId {
            arguments.append(contentsOf: ["--session", sessionId])
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        var environment = self.environment()
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
        let outputCollector = makeOutputDrainer(stdoutPipe, stderrPipe)
        outputCollector.start()
        let beep = self.beep
        let debugLog = self.debugLog
        process.terminationHandler = { [weak self] terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                self?.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0 else { return }
                // Log only non-sensitive metadata: the child's stdout/stderr can echo
                // repo paths and file contents, so report a byte count, not the text.
                debugLog("openDiffViewer exited status=\(terminationStatus) outputBytes=\(output.utf8.count)")
                beep()
            }
        }

        do {
            try process.run()
            let processIdentifier = process.processIdentifier
            processes[processIdentifier] = process
            if !process.isRunning {
                processes.removeValue(forKey: processIdentifier)
            }
            debugLog("openDiffViewer pid=\(process.processIdentifier)")
            return true
        } catch {
            outputCollector.cancel()
            debugLog("openDiffViewer failed errorType=\(type(of: error))")
            return false
        }
    }
}

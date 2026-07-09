public import Foundation
public import CmuxRemoteWorkspace

/// Spawns the bundled `cmux ssh` CLI for a validated SSH deep link and owns the
/// running-process registry so the launch lifecycle never lives on the app
/// delegate.
///
/// Lifted byte-faithfully from the legacy `AppDelegate+CmuxSSHURL`
/// `CmuxSSHURLProcessLauncher`: the `Process` construction, the
/// `["--socket", socketPath] + request.cliArguments` argument vector, the
/// environment overrides (setting `CMUX_SOCKET_PATH` / `CMUX_BUNDLED_CLI_PATH`
/// and dropping `CMUX_SOCKET`), the output draining, the missing-CLI guard, and
/// the nonzero-exit / launch-throw failure dispatch are unchanged. Three
/// app-target couplings are inverted, each behind a constructor-injected seam:
/// - the running-process map `[Int32: Process]` and the `isShuttingDown` flag,
///   formerly held on the `CmuxSSHURLProcessLauncher.shared` singleton, now
///   owned here;
/// - the `ProcessOutputCollector` (an app-target type shared by several
///   launchers), supplied through `makeOutputDrainer`
///   (``DiffViewerProcessOutputDraining``, the same seam the diff-viewer launch
///   uses);
/// - the DEBUG `cmuxDebugLog` line, supplied through `debugLog`.
///
/// The failure dialog (`NSAlert` bound to a preferred `NSWindow`) and its
/// `String(localized:)` copy stay app-side and are inverted per call through the
/// `onFailure` closure passed to ``start(request:cliURL:socketPath:onFailure:)``;
/// resolving the copy here would bind to the package bundle and drop the
/// Japanese translation, and the package cannot own `NSWindow`.
///
/// Isolation: `@MainActor`, because every launch is a main-thread UI flow and
/// the registry is mutated only on launch and from the termination handler,
/// which hops back to the main actor exactly as the legacy
/// `Task { @MainActor in … }` did.
@MainActor
@Observable
public final class CmuxSSHURLLaunchService {
    private var processes: [Int32: Process] = [:]
    private var isShuttingDown = false
    private let makeOutputDrainer: @Sendable (_ stdout: Pipe, _ stderr: Pipe) -> any DiffViewerProcessOutputDraining
    private let environment: @Sendable () -> [String: String]
    private let debugLog: @Sendable (String) -> Void

    /// Creates the service with explicit collaborators.
    /// - Parameters:
    ///   - makeOutputDrainer: Factory for a per-launch output drainer; the app
    ///     returns its `ProcessOutputCollector`, tests a recording fake.
    ///   - environment: Base environment the child inherits before the SSH-URL
    ///     overrides are applied (the app passes
    ///     `ProcessInfo.processInfo.environment`).
    ///   - debugLog: DEBUG sink for the `sshURL.launchCLI …` trace line (the app
    ///     passes `cmuxDebugLog` in DEBUG, a no-op otherwise).
    public init(
        makeOutputDrainer: @escaping @Sendable (_ stdout: Pipe, _ stderr: Pipe) -> any DiffViewerProcessOutputDraining,
        environment: @escaping @Sendable () -> [String: String],
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeOutputDrainer = makeOutputDrainer
        self.environment = environment
        self.debugLog = debugLog
    }

    /// Terminates every tracked child and marks the service shutting down so a
    /// late nonzero-exit termination does not surface a failure dialog during
    /// app teardown.
    public func terminateAll() {
        isShuttingDown = true
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }

    /// Launches `cmux ssh` for `request`.
    ///
    /// - Parameters:
    ///   - request: The validated SSH deep link to expand into the `cmux ssh`
    ///     argument vector.
    ///   - cliURL: The bundled `cmux` CLI executable, or `nil` when it is
    ///     missing from the build (the app resolves and existence-checks it).
    ///   - socketPath: The control socket the CLI talks to.
    ///   - onFailure: Presents a launch failure to the user; the app shows the
    ///     NSAlert (bound to the preferred window it captured) with app-bundle
    ///     localized copy derived from the typed ``CmuxSSHURLLaunchFailure``.
    /// - Returns: `true` when the child started, `false` when the CLI was
    ///   missing or `Process.run()` threw.
    @discardableResult
    public func start(
        request: CmuxSSHURLRequest,
        cliURL: URL?,
        socketPath: String,
        onFailure: @escaping @MainActor (CmuxSSHURLLaunchFailure) -> Void
    ) -> Bool {
        guard let cliURL,
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            onFailure(.missingCLI)
            return false
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath] + request.cliArguments
        var environment = self.environment()
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputCollector = makeOutputDrainer(outputPipe, errorPipe)
        outputCollector.start()
        process.terminationHandler = { [weak self] terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.processes.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0, !self.isShuttingDown else { return }
                onFailure(.nonzeroExit(status: terminationStatus, output: output))
            }
        }

        do {
            try process.run()
            processes[process.processIdentifier] = process
            debugLog(
                "sshURL.launchCLI pid=\(process.processIdentifier) socket=\(socketPath) targetLength=\(request.destination.count)"
            )
            return true
        } catch {
            outputCollector.cancel()
            onFailure(.launchThrew(description: error.localizedDescription))
            return false
        }
    }
}

public import Foundation
import Darwin
import CmuxCore
import CmuxFoundation

/// Owns the lifecycle of the VS Code `serve-web`/`code-server` process that
/// backs "Open Current Directory in VS Code (Inline)": it launches the process
/// on demand, parses the advertised Web UI URL, hands waiting callers that URL,
/// and tears the process (and its connection-token file) down on stop/restart.
///
/// Generation tracking (`lifecycleGeneration`/`activeLaunchGeneration`) keeps a
/// `stop()` racing an in-flight launch from dropping a newer caller's
/// completion, and from leaking a process whose generation has already been
/// superseded.
///
/// Isolation: a byte-faithful lift of the former app-target singleton. All
/// mutable state stays confined to the private serial `queue`, with launches
/// driven on `launchQueue` exactly as before, so the original generation/launch
/// races are preserved verbatim. The type is therefore `@unchecked Sendable`
/// (queue-confined state) rather than an actor; the actor/`async` rewrite is a
/// separate modernization, not part of this relocation. The de-singletonized
/// instance is constructed and held at the app composition root and injected to
/// the call sites.
public final class VSCodeServeWebController: @unchecked Sendable {
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var connectionTokenFilesByProcessID: [ObjectIdentifier: URL] = [:]
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
#if DEBUG
    private var testingTrackedProcesses: [Process] = []
#endif

    /// Creates a controller that launches the real VS Code CLI on demand.
    public init() {
        self.launchProcessOverride = nil
    }

#if DEBUG
    private init(launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?) {
        self.launchProcessOverride = launchProcessOverride
    }

    /// Builds a controller whose process launch is replaced by `launchProcessOverride`,
    /// so tests exercise the generation/teardown bookkeeping without spawning VS Code.
    public static func makeForTesting(
        launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?
    ) -> VSCodeServeWebController {
        VSCodeServeWebController(launchProcessOverride: launchProcessOverride)
    }

    /// Registers a connection-token file against a synthetic process so a test can
    /// assert that ``stop()`` removes orphaned token files.
    public func trackConnectionTokenFileForTesting(
        _ connectionTokenFileURL: URL,
        setAsLaunchingProcess: Bool = false,
        setAsServeWebProcess: Bool = false
    ) {
        let process = Process()
        queue.sync {
            if setAsLaunchingProcess {
                self.launchingProcess = process
            }
            if setAsServeWebProcess {
                self.serveWebProcess = process
            }
            if !setAsLaunchingProcess && !setAsServeWebProcess {
                self.testingTrackedProcesses.append(process)
            }
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
        }
    }
#endif

    /// Returns the running serve-web URL (launching one if needed), invoking
    /// `completion` on the main queue with the URL or `nil` on failure.
    public func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        // Queue-confined state owns the non-Sendable completion; the binding lets
        // it cross the serial-queue hops without a Sendable rewrite of the API.
        nonisolated(unsafe) let completion = completion
        queue.async {
            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }

            let completionGeneration = self.lifecycleGeneration
            self.pendingCompletions.append((generation: completionGeneration, completion: completion))
            guard !self.isLaunching else { return }

            self.isLaunching = true
            let launchGeneration = completionGeneration
            self.activeLaunchGeneration = launchGeneration

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync {
                    self.lifecycleGeneration == launchGeneration
                }
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }
                // The launch result carries a non-Sendable `Process`; bind it so the
                // queue hop that records/terminates it stays queue-confined.
                nonisolated(unsafe) let launchResult = self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: launchGeneration
                )
                self.queue.async {
                    guard self.activeLaunchGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }
                    self.isLaunching = false
                    self.activeLaunchGeneration = nil

                    guard self.lifecycleGeneration == launchGeneration else {
                        if let launchedProcess = launchResult?.process,
                           self.launchingProcess === launchedProcess {
                            self.launchingProcess = nil
                        }
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }

                    if let launchResult {
                        self.launchingProcess = nil
                        self.serveWebProcess = launchResult.process
                        self.serveWebURL = launchResult.url
                    } else {
                        self.launchingProcess = nil
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }

                    var completions: [(URL?) -> Void] = []
                    var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
                    for pending in self.pendingCompletions {
                        if pending.generation == launchGeneration {
                            completions.append(pending.completion)
                        } else {
                            remaining.append(pending)
                        }
                    }
                    self.pendingCompletions = remaining
                    let resolvedURL = self.serveWebURL
                    nonisolated(unsafe) let completionsToCall = completions
                    DispatchQueue.main.async {
                        completionsToCall.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    /// Terminates the serve-web (and in-flight launch) process, removes its
    /// connection-token files, and fails every pending completion with `nil`.
    public func stop() {
        let (processes, tokenFileURLs, completions): ([Process], [URL], [(URL?) -> Void]) = queue.sync {
            self.lifecycleGeneration &+= 1
            self.isLaunching = false
            self.activeLaunchGeneration = nil
            var processes: [Process] = []
            if let process = self.serveWebProcess {
                processes.append(process)
            }
            if let process = self.launchingProcess,
               !processes.contains(where: { $0 === process }) {
                processes.append(process)
            }
            self.serveWebProcess = nil
            self.launchingProcess = nil
#if DEBUG
            self.testingTrackedProcesses.removeAll()
#endif
            var tokenFileURLs = processes.compactMap {
                self.connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier($0))
            }
            tokenFileURLs.append(contentsOf: self.connectionTokenFilesByProcessID.values)
            self.connectionTokenFilesByProcessID.removeAll()
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            return (processes, tokenFileURLs, completions)
        }

        for tokenFileURL in tokenFileURLs {
            Self.removeConnectionTokenFile(at: tokenFileURL)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            nonisolated(unsafe) let completionsToCall = completions
            DispatchQueue.main.async {
                completionsToCall.forEach { $0(nil) }
            }
        }
    }

    /// Stops the current process and immediately launches a fresh one.
    public func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL, completion: completion)
    }

    /// Reports whether `candidateURL` is the current serve-web URL, comparing by
    /// shared loopback origin (scheme, port, and loopback-family host).
    public func isServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL else { return false }
        let serveWebURL = queue.sync {
            self.serveWebURL
        }
        return Self.urlsShareLoopbackOrigin(candidateURL, serveWebURL)
    }

    private func launchServeWebProcess(
        vscodeApplicationURL: URL,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        if let launchProcessOverride {
            return launchProcessOverride(vscodeApplicationURL, expectedGeneration)
        }

        guard let launchConfiguration = VSCodeCLILaunchConfigurationResolver().launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        guard let connectionTokenFileURL = Self.makeConnectionTokenFile() else {
            return nil
        }

        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.argumentsPrefix + [
            "--accept-server-license-terms",
            "--host", "127.0.0.1",
            "--port", "0",
            "--connection-token-file", connectionTokenFileURL.path,
        ]
        process.environment = launchConfiguration.environment

        // Pipes are non-Sendable; the readability/termination handlers run on
        // Dispatch and only touch them serially, so bind them queue-confined.
        nonisolated(unsafe) let stdoutPipe = Pipe()
        nonisolated(unsafe) let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: @Sendable (FileHandle) -> Void = { fileHandle in
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                fileHandle.readabilityHandler = nil
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = outputReader
        stderrPipe.fileHandleForReading.readabilityHandler = outputReader

        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            nonisolated(unsafe) let terminatedProcess = terminatedProcess
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === terminatedProcess {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(terminatedProcess)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(process)
                ) {
                    Self.removeConnectionTokenFile(at: tokenFileURL)
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.removeConnectionTokenFile(at: connectionTokenFileURL)
            return nil
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            } else {
                queue.sync {
                    if self.launchingProcess === process {
                        self.launchingProcess = nil
                    }
                    if self.serveWebProcess === process {
                        self.serveWebProcess = nil
                        self.serveWebURL = nil
                    }
                    if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                        forKey: ObjectIdentifier(process)
                    ) {
                        Self.removeConnectionTokenFile(at: tokenFileURL)
                    }
                }
            }
            return nil
        }

        return (process, serveWebURL)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConnectionTokenFile() -> URL? {
        let token = randomConnectionToken()
        let tokenFileName = "cmux-vscode-token-\(UUID().uuidString)"
        let tokenFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(tokenFileName, isDirectory: false)
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            removeConnectionTokenFile(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    private static func removeConnectionTokenFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func urlsShareLoopbackOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        guard lhs.scheme?.lowercased() == "http",
              rhs.scheme?.lowercased() == "http" else {
            return false
        }
        guard lhs.port == rhs.port, lhs.port != nil else { return false }
        guard let lhsHost = RemoteLoopbackProxyAlias.normalizeHost(lhs.host ?? ""),
              let rhsHost = RemoteLoopbackProxyAlias.normalizeHost(rhs.host ?? "") else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(lhsHost)
            && RemoteLoopbackProxyAlias.isLoopbackHost(rhsHost)
    }
}

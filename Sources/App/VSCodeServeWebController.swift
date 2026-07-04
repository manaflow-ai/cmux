import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60
    private static let serveWebTerminationGraceSeconds: TimeInterval = 2
    /// Used to namespace the serve-web data dir when the running app has no bundle
    /// identifier (e.g. some test hosts). Matches the release bundle id.
    private static let fallbackBundleIdentifier = "com.cmuxterm.app"

    private struct TerminationWait {
        var pendingProcessIDs: Set<ObjectIdentifier>
        let completion: () -> Void
        var deadlineTimer: DispatchSourceTimer?
    }

    private enum LaunchAttemptResult {
        case started(process: Process, url: URL)
        case portUnavailable
        case failed
    }

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private let terminationGraceSeconds: TimeInterval
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
    private var nextTerminationWaitID: UInt64 = 0
    private var terminationWaits: [UInt64: TerminationWait] = [:]
    private var isWaitingForStoppedProcesses = false
    private var terminationBarrierCompletions: [() -> Void] = []
    private var deferredServeWebRequests: [
        (vscodeApplicationURL: URL, requiredLifecycleGeneration: UInt64?, completion: (URL?) -> Void)
    ] = []

    // Internal (not private) so tests can inject `launchProcessOverride` via
    // `@testable import` instead of a `#if DEBUG` production test seam.
    init(
        launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil,
        terminationGraceSeconds: TimeInterval = VSCodeServeWebController.serveWebTerminationGraceSeconds
    ) {
        self.launchProcessOverride = launchProcessOverride
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        ensureServeWebURL(
            vscodeApplicationURL: vscodeApplicationURL,
            requiredLifecycleGeneration: nil,
            completion: completion
        )
    }

    private func ensureServeWebURL(
        vscodeApplicationURL: URL,
        requiredLifecycleGeneration: UInt64?,
        completion: @escaping (URL?) -> Void
    ) {
        queue.async {
            if let requiredLifecycleGeneration,
               self.lifecycleGeneration != requiredLifecycleGeneration {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }

            if self.isWaitingForStoppedProcesses {
                self.deferredServeWebRequests.append((
                    vscodeApplicationURL: vscodeApplicationURL,
                    requiredLifecycleGeneration: requiredLifecycleGeneration,
                    completion: completion
                ))
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
                let launchResult = self.launchServeWebProcess(
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
                    DispatchQueue.main.async {
                        completions.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    func stop() {
        stopAndNotifyAfterTermination(nil)
    }

    private func stopAndNotifyAfterTermination(_ completion: ((UInt64) -> Void)?) {
        // The connection-token file is now persisted under the stable server data
        // dir and reused across launches, so stop() must NOT delete it — doing so
        // would change the server URL and drop VS Code Web auth/Settings Sync.
        let (
            _,
            processes,
            completions,
            shouldInstallTerminationWait,
            immediateTerminationCompletion
        ): (UInt64, [Process], [(URL?) -> Void], Bool, (() -> Void)?) = queue.sync {
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
            self.serveWebURL = nil
            let completions = self.pendingCompletions.map(\.completion)
                + self.deferredServeWebRequests.map(\.completion)
            self.pendingCompletions.removeAll()
            self.deferredServeWebRequests.removeAll()

            let runningProcesses = processes.filter(\.isRunning)
            if self.isWaitingForStoppedProcesses || !runningProcesses.isEmpty {
                if let completion {
                    let stoppedGeneration = self.lifecycleGeneration
                    self.terminationBarrierCompletions.append {
                        completion(stoppedGeneration)
                    }
                }
                if !runningProcesses.isEmpty {
                    self.isWaitingForStoppedProcesses = true
                    return (self.lifecycleGeneration, processes, completions, true, nil)
                }
                return (self.lifecycleGeneration, processes, completions, false, nil)
            }

            let immediateCompletion: (() -> Void)? = completion.map { completion in
                let stoppedGeneration = self.lifecycleGeneration
                return {
                    completion(stoppedGeneration)
                }
            }
            return (self.lifecycleGeneration, processes, completions, false, immediateCompletion)
        }

        if shouldInstallTerminationWait {
            notifyAfterTermination(of: processes) { [weak self] in
                self?.finishStopTerminationBarrier()
            }
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        immediateTerminationCompletion?()

        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(nil) }
            }
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stopAndNotifyAfterTermination { [weak self] stoppedGeneration in
            self?.ensureServeWebURL(
                vscodeApplicationURL: vscodeApplicationURL,
                requiredLifecycleGeneration: stoppedGeneration,
                completion: completion
            )
        }
    }

    func isServeWebURL(_ candidateURL: URL?) -> Bool {
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

        guard let launchConfiguration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        guard let location = prepareRuntimeLocation() else { return nil }

        // Persist a stable, valid connection token so the server URL (and the
        // browser-side session keyed to its token) stays consistent across launches.
        guard VSCodeConnectionTokenStore.ensureToken(at: location.connectionTokenFileURL) != nil else {
            return nil
        }

        // Try the preferred stable port, then deterministic stable alternates if it
        // is occupied, and persist whichever one actually binds. Persisting the
        // winner locks the origin in place so it does not drift back to the
        // (possibly still-occupied) preferred port on a later launch. An ephemeral
        // port (0) is only a last resort: it changes every launch and would
        // reintroduce the auth/Settings Sync loss this fixes (#6595).
        let stableCandidates = VSCodeServeWebRuntimeLocator.candidateStablePorts(resolvedPort: location.port)

        for port in stableCandidates + [0] {
            let options = VSCodeServeWebLaunchOptionsBuilder.launchOptions(
                configuration: launchConfiguration,
                location: location,
                port: port
            )
            switch runServeWebProcess(options: options, expectedGeneration: expectedGeneration) {
            case .started(let process, let url):
                if port != 0 {
                    Self.persistPort(port)
                }
                return (process, url)
            case .portUnavailable:
                break
            case .failed:
                return nil
            }
            // Stop retrying if this launch generation was superseded mid-attempt.
            let stillCurrent = queue.sync {
                self.lifecycleGeneration == expectedGeneration
                    && self.activeLaunchGeneration == expectedGeneration
            }
            guard stillCurrent else { return nil }
        }

        return nil
    }

    /// Runs a single serve-web launch attempt for the given options. Only explicit
    /// port-bind failures are retryable; other startup failures stop the launch loop.
    /// The persisted connection-token file is intentionally never deleted here — it
    /// must survive process exits.
    private func runServeWebProcess(
        options: VSCodeServeWebLaunchOptions,
        expectedGeneration: UInt64
    ) -> LaunchAttemptResult {
        let process = Process()
        process.executableURL = options.executableURL
        process.arguments = options.arguments
        process.environment = options.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ServeWebOutputCollector()
        let outputReader: (FileHandle) -> Void = { fileHandle in
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
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === terminatedProcess {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard self.lifecycleGeneration == expectedGeneration,
                  self.activeLaunchGeneration == expectedGeneration else {
                return false
            }
            self.launchingProcess = process
            do {
                try process.run()
                return true
            } catch {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failed
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let attemptResult: LaunchAttemptResult = collector.sawPortCollision ? .portUnavailable : .failed
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
                }
            }
            return attemptResult
        }

        return .started(process: process, url: serveWebURL)
    }

    /// Resolves the stable serve-web paths + preferred port and ensures the data
    /// directories exist before launch. The actual bound port is persisted by the
    /// launch loop once a candidate succeeds.
    private func prepareRuntimeLocation() -> VSCodeServeWebRuntimeLocation? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? Self.fallbackBundleIdentifier
        let location = VSCodeServeWebRuntimeLocator.resolve(
            applicationSupportURL: applicationSupportURL,
            bundleIdentifier: bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            persistedPort: Self.persistedPort()
        )

        let fileManager = FileManager.default
        // Cmux-owned directories hold long-lived VS Code Web auth, Settings Sync,
        // and CLI keyring state, so keep them owner-only (0700) to match the 0600
        // connection-token file. serverDataDirectoryURL is created first since it
        // is the parent of the user-data/cli-data subdirectories.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        var cmuxOwnedDirectoryURLs = [
            location.serverDataDirectoryURL,
            location.userDataDirectoryURL,
        ]
        if !location.cliDataDirectoryIsExternal {
            cmuxOwnedDirectoryURLs.append(location.cliDataDirectoryURL)
        }
        for directoryURL in cmuxOwnedDirectoryURLs {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: ownerOnly
            )
            // Pin to 0700 even if the directory pre-existed with looser perms (e.g.
            // created by an older build or a wider umask).
            try? fileManager.setAttributes(ownerOnly, ofItemAtPath: directoryURL.path)
        }
        return location
    }

    private static func persistedPort() -> Int? {
        let value = UserDefaults.standard.integer(forKey: VSCodeServeWebRuntimeLocator.portUserDefaultsKey)
        return value > 0 ? value : nil
    }

    private static func persistPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: VSCodeServeWebRuntimeLocator.portUserDefaultsKey)
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

    private func notifyAfterTermination(of processes: [Process], completion: @escaping () -> Void) {
        let runningProcesses = processes.filter(\.isRunning)
        guard !runningProcesses.isEmpty else {
            completion()
            return
        }

        let processIDs = Set(runningProcesses.map(ObjectIdentifier.init))
        let waitID: UInt64 = queue.sync {
            self.nextTerminationWaitID &+= 1
            let waitID = self.nextTerminationWaitID
            self.terminationWaits[waitID] = TerminationWait(
                pendingProcessIDs: processIDs,
                completion: completion,
                deadlineTimer: nil
            )
            return waitID
        }

        for process in runningProcesses {
            let previousTerminationHandler = process.terminationHandler
            process.terminationHandler = { [weak self] terminatedProcess in
                previousTerminationHandler?(terminatedProcess)
                self?.finishTerminationWait(waitID: waitID, process: terminatedProcess)
            }
            if !process.isRunning {
                finishTerminationWait(waitID: waitID, process: process)
            }
        }

        installTerminationDeadline(waitID: waitID, processes: runningProcesses)
    }

    private func installTerminationDeadline(waitID: UInt64, processes: [Process]) {
        // DispatchSourceTimer is a one-shot deadline for non-async Process termination callbacks.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let milliseconds = max(1, Int((terminationGraceSeconds * 1_000).rounded(.up)))
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [weak self] in
            self?.handleTerminationDeadline(waitID: waitID, processes: processes)
        }

        let shouldResumeTimer: Bool = queue.sync {
            guard var wait = self.terminationWaits[waitID] else { return false }
            wait.deadlineTimer = timer
            self.terminationWaits[waitID] = wait
            return true
        }
        if shouldResumeTimer {
            timer.resume()
        } else {
            timer.resume()
            timer.cancel()
        }
    }

    private func handleTerminationDeadline(waitID: UInt64, processes: [Process]) {
        guard let wait = terminationWaits[waitID] else { return }
        for process in processes where wait.pendingProcessIDs.contains(ObjectIdentifier(process)) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            } else {
                finishTerminationWait(waitID: waitID, process: process)
            }
        }
    }

    private func finishTerminationWait(waitID: UInt64, process: Process) {
        let processID = ObjectIdentifier(process)
        queue.async {
            guard var wait = self.terminationWaits[waitID],
                  wait.pendingProcessIDs.remove(processID) != nil else {
                return
            }
            if wait.pendingProcessIDs.isEmpty {
                self.terminationWaits.removeValue(forKey: waitID)
                wait.deadlineTimer?.cancel()
                wait.completion()
            } else {
                self.terminationWaits[waitID] = wait
            }
        }
    }

    private func finishStopTerminationBarrier() {
        queue.async {
            self.isWaitingForStoppedProcesses = false
            let barrierCompletions = self.terminationBarrierCompletions
            self.terminationBarrierCompletions.removeAll()
            let deferredRequests = self.deferredServeWebRequests
            self.deferredServeWebRequests.removeAll()

            barrierCompletions.forEach { $0() }
            for request in deferredRequests {
                self.ensureServeWebURL(
                    vscodeApplicationURL: request.vscodeApplicationURL,
                    requiredLifecycleGeneration: request.requiredLifecycleGeneration,
                    completion: request.completion
                )
            }
        }
    }

    private static func urlsShareLoopbackOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        guard lhs.scheme?.lowercased() == "http",
              rhs.scheme?.lowercased() == "http" else {
            return false
        }
        guard lhs.port == rhs.port, lhs.port != nil else { return false }
        guard let lhsHost = BrowserInsecureHTTPSettings.normalizeHost(lhs.host ?? ""),
              let rhsHost = BrowserInsecureHTTPSettings.normalizeHost(rhs.host ?? "") else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(lhsHost)
            && RemoteLoopbackProxyAlias.isLoopbackHost(rhsHost)
    }
}

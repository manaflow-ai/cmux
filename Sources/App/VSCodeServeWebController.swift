import CmuxFoundation
import Foundation

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60

    private enum LaunchAttemptResult {
        case launched(process: Process, url: URL)
        case failed(retryable: Bool)
    }

    private let queue = DispatchQueue(label: "cmux.vscode.serveWeb")
    private let launchQueue = DispatchQueue(label: "cmux.vscode.serveWeb.launch")
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private let launchConfigurationBuilder: VSCodeCLILaunchConfigurationBuilder
    private var serveWebProcess: Process?
    private var launchingProcess: Process?
    private var serveWebURL: URL?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0

    init(
        launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil,
        launchConfigurationBuilder: VSCodeCLILaunchConfigurationBuilder = VSCodeCLILaunchConfigurationBuilder()
    ) {
        self.launchProcessOverride = launchProcessOverride
        self.launchConfigurationBuilder = launchConfigurationBuilder
    }

    func ensureServeWebURL(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        queue.async {
            if let process = self.serveWebProcess,
               process.isRunning,
               let url = self.serveWebURL {
                Self.completeOnMain(completion, with: url)
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
                    Self.completeOnMain(completions, with: self.serveWebURL)
                }
            }
        }
    }

    func stop() {
        let (processes, completions): ([Process], [(URL?) -> Void]) = queue.sync {
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
            self.pendingCompletions.removeAll()
            return (processes, completions)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            Self.completeOnMain(completions, with: nil)
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL, completion: completion)
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

        guard let launchConfiguration = launchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: vscodeApplicationURL
        ) else { return nil }

        // Use the child-process environment so CMUX_* overrides that survive
        // nodeSafeEnvironment are also honored by serve-web option resolution.
        guard let launchOptions = VSCodeServeWebLaunchOptions.resolve(
            environment: launchConfiguration.environment
        ) else { return nil }

        let launchOptionCandidates = [launchOptions] + [launchOptions.ephemeralPortFallback()].compactMap { $0 }
        for launchOptions in launchOptionCandidates {
            switch launchServeWebProcessCandidate(
                launchConfiguration: launchConfiguration,
                launchOptions: launchOptions,
                expectedGeneration: expectedGeneration
            ) {
            case .launched(let process, let url):
                return (process, url)
            case .failed(let retryable):
                guard retryable else { return nil }
            }
        }
        return nil
    }

    private func launchServeWebProcessCandidate(
        launchConfiguration: VSCodeCLILaunchConfiguration,
        launchOptions: VSCodeServeWebLaunchOptions,
        expectedGeneration: UInt64
    ) -> LaunchAttemptResult {
        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.processArguments(for: launchOptions)
        process.environment = launchConfiguration.processEnvironment(for: launchOptions)

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
            return .failed(retryable: true)
        }

        guard collector.waitForURL(timeoutSeconds: Self.serveWebStartupTimeoutSeconds),
              let serveWebURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                Self.terminateAndWaitForExit(process)
            }
            queue.sync {
                if self.launchingProcess === process {
                    self.launchingProcess = nil
                }
                if self.serveWebProcess === process {
                    self.serveWebProcess = nil
                    self.serveWebURL = nil
                }
            }
            return .failed(retryable: !process.isRunning)
        }

        return .launched(process: process, url: serveWebURL)
    }

    private static func terminateAndWaitForExit(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    private static func completeOnMain(_ completion: @escaping (URL?) -> Void, with url: URL?) {
        DispatchQueue.main.async {
            completion(url)
        }
    }

    private static func completeOnMain(_ completions: [(URL?) -> Void], with url: URL?) {
        DispatchQueue.main.async {
            completions.forEach { $0(url) }
        }
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

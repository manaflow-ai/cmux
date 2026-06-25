import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

final class VSCodeServeWebController {
    static let shared = VSCodeServeWebController()
    private static let serveWebStartupTimeoutSeconds: TimeInterval = 60
    private static let serveWebTerminationTimeoutSeconds: TimeInterval = 5
    private static let serveWebKillTimeoutSeconds: TimeInterval = 2

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
                let shouldLaunch = self.queue.sync(execute: {
                    self.lifecycleGeneration == launchGeneration
                })
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }
                self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: launchGeneration
                )
            }
        }
    }

    func stop() {
        let (processes, completions): ([Process], [(URL?) -> Void]) = queue.sync(execute: {
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
        })

        for process in processes where process.isRunning {
            process.terminate()
        }

        if !completions.isEmpty {
            Self.completeOnMain(completions, with: nil)
        }
    }

    func restart(vscodeApplicationURL: URL, completion: @escaping (URL?) -> Void) {
        let (restartGeneration, processes, cancelledCompletions): (UInt64, [Process], [(URL?) -> Void]) = queue.sync(execute: {
            self.lifecycleGeneration &+= 1
            let restartGeneration = self.lifecycleGeneration
            self.isLaunching = true
            self.activeLaunchGeneration = restartGeneration
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
            let cancelledCompletions = self.pendingCompletions.map(\.completion)
            self.pendingCompletions.removeAll()
            self.pendingCompletions.append((generation: restartGeneration, completion: completion))
            return (restartGeneration, processes, cancelledCompletions)
        })

        if !cancelledCompletions.isEmpty {
            Self.completeOnMain(cancelledCompletions, with: nil)
        }

        Self.terminateProcessesBeforeRestart(
            processes,
            on: queue,
            terminationTimeout: Self.serveWebTerminationTimeoutSeconds,
            killTimeout: Self.serveWebKillTimeoutSeconds
        ) { [weak self] didTerminate in
            guard let self else { return }
            guard didTerminate else {
                self.completeServeWebLaunch(nil, expectedGeneration: restartGeneration)
                return
            }

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync(execute: {
                    self.lifecycleGeneration == restartGeneration
                        && self.activeLaunchGeneration == restartGeneration
                })
                guard shouldLaunch else { return }
                self.launchServeWebProcess(
                    vscodeApplicationURL: vscodeApplicationURL,
                    expectedGeneration: restartGeneration
                )
            }
        }
    }

    func isServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL else { return false }
        let serveWebURL = queue.sync(execute: {
            self.serveWebURL
        })
        return Self.urlsShareLoopbackOrigin(candidateURL, serveWebURL)
    }

    @discardableResult
    func prepareRestoredServeWebURL(
        _ candidateURL: URL?,
        vscodeApplicationURL: URL?,
        completion: ((URL?) -> Void)? = nil
    ) -> Bool {
        guard let restoredURL = candidateURL,
              Self.isPersistentServeWebURL(restoredURL) else {
            return false
        }
        guard let vscodeApplicationURL else {
            if let completion {
                Self.completeOnMain(completion, with: nil)
            }
            return true
        }
        ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { url in
            completion?(Self.preparedRestoredServeWebURL(restoredURL, launchedURL: url))
        }
        return true
    }

    private func launchServeWebProcess(
        vscodeApplicationURL: URL,
        expectedGeneration: UInt64
    ) {
        if let launchProcessOverride {
            completeServeWebLaunch(
                launchProcessOverride(vscodeApplicationURL, expectedGeneration),
                expectedGeneration: expectedGeneration
            )
            return
        }

        let launchConfigurations = launchConfigurationBuilder.launchConfigurations(
            vscodeApplicationURL: vscodeApplicationURL
        )
        guard let primaryLaunchConfiguration = launchConfigurations.first else {
            completeServeWebLaunch(nil, expectedGeneration: expectedGeneration)
            return
        }

        // Use the child-process environment so CMUX_* overrides that survive
        // nodeSafeEnvironment are also honored by serve-web option resolution.
        guard let launchOptions = VSCodeServeWebLaunchOptions.resolve(
            environment: primaryLaunchConfiguration.environment
        ) else {
            completeServeWebLaunch(nil, expectedGeneration: expectedGeneration)
            return
        }

        let launchOptionCandidates = [launchOptions] + [launchOptions.ephemeralPortFallback()].compactMap { $0 }
        let launchCandidates = launchOptionCandidates.flatMap { launchOptions in
            launchConfigurations.map { launchConfiguration in
                (launchConfiguration: launchConfiguration, launchOptions: launchOptions)
            }
        }
        launchServeWebProcessCandidate(
            launchCandidates: launchCandidates,
            index: 0,
            expectedGeneration: expectedGeneration
        )
    }

    private func launchServeWebProcessCandidate(
        launchCandidates: [(launchConfiguration: VSCodeCLILaunchConfiguration, launchOptions: VSCodeServeWebLaunchOptions)],
        index: Int,
        expectedGeneration: UInt64
    ) {
        let shouldContinue = queue.sync(execute: {
            self.lifecycleGeneration == expectedGeneration
                && self.activeLaunchGeneration == expectedGeneration
        })
        guard shouldContinue else { return }

        guard index < launchCandidates.count else {
            completeServeWebLaunch(nil, expectedGeneration: expectedGeneration)
            return
        }

        let launchCandidate = launchCandidates[index]
        launchServeWebProcessCandidate(
            launchConfiguration: launchCandidate.launchConfiguration,
            launchOptions: launchCandidate.launchOptions,
            expectedGeneration: expectedGeneration
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .launched(let process, let url):
                self.completeServeWebLaunch((process, url), expectedGeneration: expectedGeneration)
            case .failed(let retryable):
                guard retryable else {
                    self.completeServeWebLaunch(nil, expectedGeneration: expectedGeneration)
                    return
                }
                self.launchServeWebProcessCandidate(
                    launchCandidates: launchCandidates,
                    index: index + 1,
                    expectedGeneration: expectedGeneration
                )
            }
        }
    }

    private func launchServeWebProcessCandidate(
        launchConfiguration: VSCodeCLILaunchConfiguration,
        launchOptions: VSCodeServeWebLaunchOptions,
        expectedGeneration: UInt64,
        completion: @escaping (VSCodeServeWebLaunchAttemptResult) -> Void
    ) {
        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.processArguments(for: launchOptions)
        process.environment = launchConfiguration.processEnvironment(for: launchOptions)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var startupTimer: DispatchSourceTimer?
        var terminationTimer: DispatchSourceTimer?
        var killTimer: DispatchSourceTimer?
        var didFinish = false

        func cancelTimers() {
            startupTimer?.cancel()
            terminationTimer?.cancel()
            killTimer?.cancel()
            startupTimer = nil
            terminationTimer = nil
            killTimer = nil
        }

        func clearOutputHandlers() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        func finish(_ result: VSCodeServeWebLaunchAttemptResult) {
            guard !didFinish else { return }
            didFinish = true
            cancelTimers()
            completion(result)
        }

        func finishFromProcessExit(collector: ServeWebOutputCollector) {
            clearOutputHandlers()
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            // A URL discovered only after Process termination is not a usable serve-web instance.
            finish(.failed(retryable: true))
        }

        func scheduleKillDeadline() {
            killTimer = makeDeadlineTimer(after: Self.serveWebKillTimeoutSeconds) {
                finish(.failed(retryable: !process.isRunning))
            }
            killTimer?.resume()
        }

        func scheduleTerminationDeadline() {
            terminationTimer = makeDeadlineTimer(after: Self.serveWebTerminationTimeoutSeconds) {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    scheduleKillDeadline()
                } else {
                    finish(.failed(retryable: true))
                }
            }
            terminationTimer?.resume()
        }

        let collector = ServeWebOutputCollector { [weak self, weak process] url in
            guard let self, let process, let url else { return }
            self.launchQueue.async {
                guard process.isRunning else {
                    finish(.failed(retryable: true))
                    return
                }
                finish(.launched(process: process, url: url))
            }
        }

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
            self?.launchQueue.async {
                terminatedProcess.terminationHandler = nil
                finishFromProcessExit(collector: collector)
            }
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

        let didStart: Bool = queue.sync(execute: {
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
        })
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            completion(.failed(retryable: true))
            return
        }

        startupTimer = makeDeadlineTimer(after: Self.serveWebStartupTimeoutSeconds) {
            guard !didFinish else { return }
            clearOutputHandlers()
            if let serveWebURL = collector.webUIURL, process.isRunning {
                finish(.launched(process: process, url: serveWebURL))
                return
            }
            guard process.isRunning else {
                Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
                Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
                process.terminationHandler = nil
                finish(.failed(retryable: true))
                return
            }
            process.terminate()
            scheduleTerminationDeadline()
        }
        startupTimer?.resume()
    }

    private func completeServeWebLaunch(
        _ launchResult: (process: Process, url: URL)?,
        expectedGeneration: UInt64
    ) {
        queue.async {
            let activeLaunchResult: (process: Process, url: URL)?
            if let launchResult, launchResult.process.isRunning {
                activeLaunchResult = launchResult
            } else {
                activeLaunchResult = nil
            }

            guard self.activeLaunchGeneration == expectedGeneration else {
                if let process = activeLaunchResult?.process, process.isRunning {
                    process.terminate()
                }
                return
            }
            self.isLaunching = false
            self.activeLaunchGeneration = nil

            guard self.lifecycleGeneration == expectedGeneration else {
                if let launchedProcess = activeLaunchResult?.process,
                   self.launchingProcess === launchedProcess {
                    self.launchingProcess = nil
                }
                if let process = activeLaunchResult?.process, process.isRunning {
                    process.terminate()
                }
                return
            }

            if let activeLaunchResult {
                self.launchingProcess = nil
                self.serveWebProcess = activeLaunchResult.process
                self.serveWebURL = activeLaunchResult.url
            } else {
                self.launchingProcess = nil
                self.serveWebProcess = nil
                self.serveWebURL = nil
            }

            var completions: [(URL?) -> Void] = []
            var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
            for pending in self.pendingCompletions {
                if pending.generation == expectedGeneration {
                    completions.append(pending.completion)
                } else {
                    remaining.append(pending)
                }
            }
            self.pendingCompletions = remaining
            Self.completeOnMain(completions, with: self.serveWebURL)
        }
    }

    private func makeDeadlineTimer(after seconds: TimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        // Process and FileHandle callbacks here are non-async, so one-shot DispatchSource timers model deadlines without blocking launchQueue.
        let timer = DispatchSource.makeTimerSource(queue: launchQueue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        return timer
    }
}

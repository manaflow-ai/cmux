import Darwin
import Foundation

/// Launches and owns one headless Chromium process for a browser-engine session.
actor ChromiumProcessController {
    private let launchTimeout: Duration
    private let terminationTimeout: Duration
    private var process: Process?
    private var stderrTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, any Error>?
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []
    private var didResolveEndpoint = false

    init(
        launchTimeout: Duration = .seconds(10),
        terminationTimeout: Duration = .seconds(1)
    ) {
        self.launchTimeout = launchTimeout
        self.terminationTimeout = terminationTimeout
    }

    /// Returns the identifier of the Chromium process while it is running.
    func processIdentifier() -> Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func start(application: BrowserApplication, userDataDirectory: URL) async throws -> URL {
        guard process == nil else {
            throw BrowserEngineSessionError.chromiumLaunch("Chromium is already running for this session.")
        }
        didResolveEndpoint = false
        endpointContinuation = nil
        try FileManager.default.createDirectory(
            at: userDataDirectory,
            withIntermediateDirectories: true
        )

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = application.executableURL
        process.arguments = [
            "--headless=new",
            "--remote-debugging-port=0",
            "--remote-allow-origins=*",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-component-update",
            "--disable-background-networking",
            "about:blank",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            let processIdentifier = process.processIdentifier
            Task {
                await self?.processDidTerminate(processIdentifier: processIdentifier)
            }
        }
        do {
            try process.run()
        } catch {
            throw error
        }
        self.process = process

        return try await withCheckedThrowingContinuation { continuation in
            endpointContinuation = continuation
            stderrTask = Task { [weak self] in
                await self?.consumeStandardError(stderrPipe.fileHandleForReading)
            }
            timeoutTask = Task { [weak self, launchTimeout] in
                // A bounded launch deadline is intentional behavior; never leave a pane waiting forever for DevTools.
                try? await ContinuousClock().sleep(for: launchTimeout)
                guard !Task.isCancelled else { return }
                await self?.failUnresolvedEndpoint(
                    BrowserEngineSessionError.chromiumLaunch("Chromium timed out before opening its DevTools endpoint.")
                )
            }
        }
    }

    func close() async {
        stderrTask?.cancel()
        stderrTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if !didResolveEndpoint {
            failUnresolvedEndpoint(BrowserEngineSessionError.chromiumLaunch(
                "Chromium stopped before opening its DevTools endpoint."
            ))
        }
        guard let process else {
            endpointContinuation = nil
            resumeTerminationContinuations()
            return
        }
        endpointContinuation = nil
        let processIdentifier = process.processIdentifier
        guard process.isRunning else {
            finishProcessTermination(processIdentifier: processIdentifier)
            return
        }
        process.terminate()
        startTerminationDeadlineIfNeeded(processIdentifier: processIdentifier)
        await withCheckedContinuation { continuation in
            terminationContinuations.append(continuation)
        }
    }

    private func failUnresolvedEndpoint(_ error: any Error) {
        guard !didResolveEndpoint else { return }
        didResolveEndpoint = true
        timeoutTask?.cancel()
        timeoutTask = nil
        endpointContinuation?.resume(throwing: error)
        endpointContinuation = nil
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func consumeStandardError(_ handle: FileHandle) async {
        do {
            for try await line in handle.bytes.lines {
                resolveEndpointIfPresent(in: line)
            }
            if !didResolveEndpoint {
                failUnresolvedEndpoint(BrowserEngineSessionError.chromiumLaunch(
                    "Chromium stopped before opening its DevTools endpoint."
                ))
            }
        } catch {
            failUnresolvedEndpoint(error)
        }
    }

    private func processDidTerminate(processIdentifier: Int32) {
        if !didResolveEndpoint {
            failUnresolvedEndpoint(BrowserEngineSessionError.chromiumLaunch(
                "Chromium stopped before opening its DevTools endpoint."
            ))
        }
        finishProcessTermination(processIdentifier: processIdentifier)
    }

    private func startTerminationDeadlineIfNeeded(processIdentifier: Int32) {
        guard terminationDeadlineTask == nil else { return }
        terminationDeadlineTask = Task { [weak self, terminationTimeout] in
            // A bounded shutdown deadline is intentional; a stuck Chromium must not block its profile forever.
            do {
                try await ContinuousClock().sleep(for: terminationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.forceTerminateProcess(processIdentifier: processIdentifier)
        }
    }

    private func forceTerminateProcess(processIdentifier: Int32) {
        guard let process, process.processIdentifier == processIdentifier else { return }
        if process.isRunning {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        finishProcessTermination(processIdentifier: processIdentifier)
    }

    private func finishProcessTermination(processIdentifier: Int32) {
        guard let process, process.processIdentifier == processIdentifier else { return }
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = nil
        self.process = nil
        resumeTerminationContinuations()
    }

    private func resumeTerminationContinuations() {
        let continuations = terminationContinuations
        terminationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resolveEndpointIfPresent(in line: String) {
        guard !didResolveEndpoint else { return }
        let marker = "DevTools listening on "
        guard let range = line.range(of: marker),
              let url = URL(string: String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        didResolveEndpoint = true
        timeoutTask?.cancel()
        timeoutTask = nil
        endpointContinuation?.resume(returning: url)
        endpointContinuation = nil
    }
}

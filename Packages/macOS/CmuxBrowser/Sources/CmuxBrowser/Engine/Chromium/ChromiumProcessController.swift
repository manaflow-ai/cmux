import Foundation

/// Launches and owns one headless Chromium process for a browser-engine session.
actor ChromiumProcessController {
    private let launchTimeout: Duration
    private var process: Process?
    private var stderrTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, any Error>?
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []
    private var didResolveEndpoint = false

    init(launchTimeout: Duration = .seconds(10)) {
        self.launchTimeout = launchTimeout
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
        process.terminationHandler = { [weak self] _ in
            Task {
                await self?.processDidTerminate()
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
            return
        }
        endpointContinuation = nil
        guard process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
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

    private func processDidTerminate() {
        if !didResolveEndpoint {
            failUnresolvedEndpoint(BrowserEngineSessionError.chromiumLaunch(
                "Chromium stopped before opening its DevTools endpoint."
            ))
        }
        process = nil
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

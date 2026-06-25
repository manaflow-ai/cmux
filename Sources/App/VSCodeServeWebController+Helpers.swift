import CmuxCore
import CmuxFoundation
import Darwin
import Foundation

extension VSCodeServeWebController {
    static func completeOnMain(_ completion: @escaping (URL?) -> Void, with url: URL?) {
        Task { @MainActor in
            completion(url)
        }
    }

    static func completeOnMain(_ completions: [(URL?) -> Void], with url: URL?) {
        Task { @MainActor in
            completions.forEach { $0(url) }
        }
    }

    static func drainAvailableOutput(from fileHandle: FileHandle, collector: ServeWebOutputCollector) {
        while true {
            switch fileHandle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                collector.append(data)
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }

    static func urlsShareLoopbackOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
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

    static func isPersistentServeWebURL(_ candidateURL: URL?) -> Bool {
        guard isPossiblePersistentServeWebURL(candidateURL) else { return false }
        return isPersistentServeWebURL(
            candidateURL,
            launchOptions: VSCodeServeWebLaunchOptions.resolve()
        )
    }

    static func isPersistentServeWebURL(
        _ candidateURL: URL?,
        launchOptions: VSCodeServeWebLaunchOptions?
    ) -> Bool {
        guard isPossiblePersistentServeWebURL(candidateURL),
              let candidateURL,
              let launchOptions,
              candidateURL.port == launchOptions.port,
              let token = VSCodeServeWebLaunchOptions.usableConnectionToken(
                launchOptions.connectionTokenFileURL,
                fileManager: .default
              ) else {
            return false
        }
        return connectionTokenQueryValue(candidateURL) == token
    }

    static func preparedRestoredServeWebURL(_ restoredURL: URL, launchedURL: URL?) -> URL? {
        guard let launchedURL,
              connectionTokenQueryValue(restoredURL) == connectionTokenQueryValue(launchedURL),
              isLoopbackHTTPURL(launchedURL) else {
            return nil
        }
        if urlsShareLoopbackOrigin(restoredURL, launchedURL) {
            return restoredURL
        }
        return serveWebURL(restoredURL, rewrittenToLoopbackOrigin: launchedURL)
    }

    static func serveWebURL(_ sourceURL: URL, rewrittenToLoopbackOrigin originURL: URL) -> URL? {
        guard connectionTokenQueryValue(sourceURL) == connectionTokenQueryValue(originURL),
              isLoopbackHTTPURL(sourceURL),
              isLoopbackHTTPURL(originURL) else {
            return nil
        }
        var sourceComponents = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        let originComponents = URLComponents(url: originURL, resolvingAgainstBaseURL: false)
        sourceComponents?.scheme = originComponents?.scheme
        sourceComponents?.host = originComponents?.host
        sourceComponents?.port = originComponents?.port
        return sourceComponents?.url
    }

    static func serveWebURLForPersistence(_ sourceURL: URL, rewrittenToLoopbackOrigin originURL: URL) -> URL? {
        guard isLoopbackHTTPURL(sourceURL),
              isLoopbackHTTPURL(originURL),
              let originToken = connectionTokenQueryValue(originURL) else {
            return nil
        }
        if let sourceToken = connectionTokenQueryValue(sourceURL) {
            guard sourceToken == originToken else { return nil }
        } else {
            guard serveWebURLMatchesPersistentURLWithoutToken(sourceURL, persistentURL: originURL) else {
                return nil
            }
        }

        var sourceComponents = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        let originComponents = URLComponents(url: originURL, resolvingAgainstBaseURL: false)
        sourceComponents?.scheme = originComponents?.scheme
        sourceComponents?.host = originComponents?.host
        sourceComponents?.port = originComponents?.port

        var queryItems = sourceComponents?.queryItems ?? []
        if let tokenIndex = queryItems.firstIndex(where: { $0.name == "tkn" }) {
            queryItems[tokenIndex] = URLQueryItem(name: "tkn", value: originToken)
        } else {
            queryItems.insert(URLQueryItem(name: "tkn", value: originToken), at: 0)
        }
        sourceComponents?.queryItems = queryItems
        return sourceComponents?.url
    }

    static func stableServeWebURL(
        for launchedURL: URL,
        launchOptions: VSCodeServeWebLaunchOptions? = VSCodeServeWebLaunchOptions.resolve()
    ) -> URL? {
        guard isLoopbackHTTPURL(launchedURL),
              let launchOptions,
              launchedURL.port != launchOptions.port,
              let token = VSCodeServeWebLaunchOptions.usableConnectionToken(
                launchOptions.connectionTokenFileURL,
                fileManager: .default
              ),
              connectionTokenQueryValue(launchedURL) == token else {
            return nil
        }
        var components = URLComponents(url: launchedURL, resolvingAgainstBaseURL: false)
        components?.port = launchOptions.port
        return components?.url
    }

    static func persistentServeWebSnapshotOrigin(
        for launchedURL: URL,
        launchOptions: VSCodeServeWebLaunchOptions? = VSCodeServeWebLaunchOptions.resolve()
    ) -> URL? {
        if let stableURL = stableServeWebURL(for: launchedURL, launchOptions: launchOptions) {
            return stableURL
        }
        guard isPersistentServeWebURL(launchedURL, launchOptions: launchOptions) else { return nil }
        return launchedURL
    }

    private static func isPossiblePersistentServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL, isLoopbackHTTPURL(candidateURL) else { return false }
        return connectionTokenQueryValue(candidateURL) != nil
    }

    private static func isLoopbackHTTPURL(_ candidateURL: URL) -> Bool {
        guard candidateURL.scheme?.lowercased() == "http",
              candidateURL.port != nil,
              let host = BrowserInsecureHTTPSettings.normalizeHost(candidateURL.host ?? "") else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(host)
    }

    private static func connectionTokenQueryValue(_ url: URL) -> String? {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        let tokenQueryItems = queryItems.filter { $0.name == "tkn" }
        guard tokenQueryItems.count == 1,
              let value = tokenQueryItems.first?.value,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func serveWebURLMatchesPersistentURLWithoutToken(_ sourceURL: URL, persistentURL: URL) -> Bool {
        guard sourceURL.path == persistentURL.path else { return false }
        return queryItemsExcludingConnectionToken(sourceURL) == queryItemsExcludingConnectionToken(persistentURL)
    }

    private static func queryItemsExcludingConnectionToken(_ url: URL) -> [URLQueryItem]? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name != "tkn" }
    }

    static func terminateProcessesBeforeRestart(
        _ processes: [Process],
        on queue: DispatchQueue,
        terminationTimeout: TimeInterval,
        killTimeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let runningProcesses = processes.filter(\.isRunning)
        guard !runningProcesses.isEmpty else {
            completion(true)
            return
        }

        queue.async {
            var remainingProcessIDs = Set(runningProcesses.map { ObjectIdentifier($0) })
            var terminationTimer: DispatchSourceTimer?
            var killTimer: DispatchSourceTimer?
            var didComplete = false

            func complete(_ didTerminate: Bool) {
                guard !didComplete else { return }
                didComplete = true
                terminationTimer?.setEventHandler {}
                killTimer?.setEventHandler {}
                terminationTimer?.cancel()
                killTimer?.cancel()
                terminationTimer = nil
                killTimer = nil
                for process in runningProcesses {
                    process.terminationHandler = nil
                }
                completion(didTerminate)
            }

            func markTerminated(_ process: Process) {
                remainingProcessIDs.remove(ObjectIdentifier(process))
                if remainingProcessIDs.isEmpty {
                    complete(true)
                }
            }

            for process in runningProcesses {
                let previousTerminationHandler = process.terminationHandler
                process.terminationHandler = { terminatedProcess in
                    previousTerminationHandler?(terminatedProcess)
                    queue.async {
                        markTerminated(terminatedProcess)
                    }
                }
            }

            for process in runningProcesses {
                if process.isRunning {
                    process.terminate()
                } else {
                    markTerminated(process)
                }
            }
            guard !remainingProcessIDs.isEmpty else { return }

            // Restart must be ordered after process exit so our stable-port retry
            // does not fall back to port 0 while the old server is still exiting.
            terminationTimer = DispatchSource.makeTimerSource(queue: queue)
            terminationTimer?.schedule(deadline: .now() + terminationTimeout)
            terminationTimer?.setEventHandler {
                for process in runningProcesses
                where remainingProcessIDs.contains(ObjectIdentifier(process)) && process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }

                killTimer = DispatchSource.makeTimerSource(queue: queue)
                killTimer?.schedule(deadline: .now() + killTimeout)
                killTimer?.setEventHandler {
                    for process in runningProcesses
                    where remainingProcessIDs.contains(ObjectIdentifier(process)) && !process.isRunning {
                        markTerminated(process)
                    }
                    if !remainingProcessIDs.isEmpty {
                        complete(false)
                    }
                }
                killTimer?.resume()
            }
            terminationTimer?.resume()
        }
    }
}

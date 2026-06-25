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
              ),
              let queryItems = URLComponents(url: candidateURL, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        let tokenQueryItems = queryItems.filter { $0.name == "tkn" }
        return tokenQueryItems.count == 1 && tokenQueryItems.first?.value == token
    }

    private static func isPossiblePersistentServeWebURL(_ candidateURL: URL?) -> Bool {
        guard let candidateURL,
              candidateURL.scheme?.lowercased() == "http",
              candidateURL.port != nil,
              let host = BrowserInsecureHTTPSettings.normalizeHost(candidateURL.host ?? ""),
              RemoteLoopbackProxyAlias.isLoopbackHost(host),
              let queryItems = URLComponents(url: candidateURL, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return queryItems.contains { $0.name == "tkn" && $0.value?.isEmpty == false }
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
                terminationTimer?.cancel()
                killTimer?.cancel()
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

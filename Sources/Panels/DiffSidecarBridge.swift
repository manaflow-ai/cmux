import Foundation
import WebKit

// Swift 6.0 cannot mark nested type declarations `nonisolated`. File scope
// keeps these process-result values outside the bridge's main-actor domain.
private enum InvocationCompletion: Sendable {
    case ready(Bool)
    case terminated(Int32)
    case timedOut
    case missingTermination
    case cancelled
}

private enum InvocationError: Error {
    case timedOut
    case missingTermination
}

/// Reply-capable transport for the Rust diff sidecar. Each request is a bounded
/// stdin/stdout exchange with a short-lived child process. The sidecar never
/// opens a socket, and WebKit never receives filesystem paths or process access.
@MainActor
final class DiffSidecarBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxDiff"
    static let shared = DiffSidecarBridge()

    private static var handlerInstalledKey: UInt8 = 0
    private static let maximumRequestBytes = 1024 * 1024
    private nonisolated static let maximumResponseBytes = 32 * 1024 * 1024
    private nonisolated static let processPool = DiffSidecarProcessPool(limit: 4)
    private nonisolated static let processGroupReadyMarker = Data("cmux-diff-sidecar-process-group-ready\n".utf8)
    private nonisolated static let startupTimeout: TimeInterval = 5
    private nonisolated static let terminationGrace: TimeInterval = 0.25
    private static let pendingSessionID = "00000000-0000-0000-0000-000000000000"
    // Longer than the sidecar's 120-second branch regeneration limit.
    private nonisolated static let requestTimeout: TimeInterval = 130
    private struct ViewerInvocationKey: Hashable {
        let webView: ObjectIdentifier
        let token: String
    }
    private var invocations: [UUID: Task<Void, Never>] = [:]
    private var sessionInvocationByViewer: [ViewerInvocationKey: UUID] = [:]
    private var discardedSessionInvocations: Set<UUID> = []

    /// Faults the Rust executable and its dynamic dependencies into the OS cache
    /// during app startup. The handshake uses stdio and exits; it never binds a
    /// port or leaves a sidecar process running.
    nonisolated static func prewarm() {
        Task.detached(priority: .utility) {
            let request = Data(#"{"id":"prewarm","version":1,"method":"protocolHandshake"}"#.utf8)
            _ = try? await processPool.run(request: request)
        }
    }

    static func installIfNeeded(on userContentController: WKUserContentController) {
        guard objc_getAssociatedObject(userContentController, &handlerInstalledKey) == nil else {
            return
        }
        userContentController.addScriptMessageHandler(
            shared,
            contentWorld: .page,
            name: handlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &handlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func installViewerBridges(on userContentController: WKUserContentController) {
        DiffCommentsBridge.installIfNeeded(on: userContentController)
        installIfNeeded(on: userContentController)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard Self.isTrustedSidecarFrame(message.frameInfo),
              JSONSerialization.isValidJSONObject(message.body),
              let body = message.body as? [String: Any] else {
            replyHandler(Self.failureResponse(body: message.body, code: "notAllowed", message: "Diff sidecar request was rejected"), nil)
            return
        }

        let invocationID = UUID()
        let method = body["method"] as? String
        var sidecarBody = body
        var discardedSessionCloseRequest: Data?
        if method == "sessionOpen",
           var params = body["params"] as? [String: Any],
           let capabilityToken = params["capabilityToken"] as? String {
            let sessionID = UUID().uuidString
            params["sessionId"] = sessionID
            sidecarBody["params"] = params
            discardedSessionCloseRequest = Self.sessionCloseRequest(
                capabilityToken: capabilityToken,
                sessionID: sessionID
            )
        }
        guard let request = try? JSONSerialization.data(withJSONObject: sidecarBody),
              request.count <= Self.maximumRequestBytes else {
            replyHandler(Self.failureResponse(body: message.body, code: "notAllowed", message: "Diff sidecar request was rejected"), nil)
            return
        }
        let viewerToken = DiffCommentsBridge.diffViewerToken(from: message.frameInfo.request.url)
        let viewerKey = message.webView.flatMap { webView in
            viewerToken.map { ViewerInvocationKey(webView: ObjectIdentifier(webView), token: $0) }
        }
        let closeSessionID = ((message.body as? [String: Any])?["params"] as? [String: Any])?["sessionId"] as? String
        if method == "sessionClose",
           closeSessionID == Self.pendingSessionID {
            if let viewerKey, let pendingID = sessionInvocationByViewer[viewerKey] {
                discardedSessionInvocations.insert(pendingID)
                invocations[pendingID]?.cancel()
            }
            replyHandler([
                "id": (message.body as? [String: Any])?["id"] as? String ?? "unknown",
                "version": 1,
                "result": ["type": "sessionClosed"],
                "error": NSNull(),
            ], nil)
            return
        }
        if method == "sessionOpen", let viewerKey,
           let previousID = sessionInvocationByViewer[viewerKey] {
            discardedSessionInvocations.insert(previousID)
            invocations[previousID]?.cancel()
        }

        let task = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await Self.processPool.run(request: request))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            if self.discardedSessionInvocations.remove(invocationID) != nil,
               let discardedSessionCloseRequest {
                await Self.closeDiscardedSession(request: discardedSessionCloseRequest)
            }
            switch result {
            case .success(let responseData):
                guard let response = try? JSONSerialization.jsonObject(with: responseData) else {
                    replyHandler(Self.failureResponse(body: message.body, code: "invalidResponse", message: "Diff sidecar returned invalid JSON"), nil)
                    self.finishInvocation(invocationID, viewerKey: viewerKey)
                    return
                }
                replyHandler(response, nil)
            case .failure:
                replyHandler(Self.failureResponse(body: message.body, code: "sidecarUnavailable", message: "Diff sidecar is unavailable"), nil)
            }
            self.finishInvocation(invocationID, viewerKey: viewerKey)
        }
        invocations[invocationID] = task
        if method == "sessionOpen", let viewerKey {
            sessionInvocationByViewer[viewerKey] = invocationID
        }
    }

    private func finishInvocation(_ invocationID: UUID, viewerKey: ViewerInvocationKey?) {
        invocations.removeValue(forKey: invocationID)
        discardedSessionInvocations.remove(invocationID)
        if let viewerKey, sessionInvocationByViewer[viewerKey] == invocationID {
            sessionInvocationByViewer.removeValue(forKey: viewerKey)
        }
    }

    nonisolated private static func sessionCloseRequest(
        capabilityToken: String,
        sessionID: String
    ) -> Data? {
        let close: [String: Any] = [
            "id": UUID().uuidString,
            "version": 1,
            "method": "sessionClose",
            "params": [
                "capabilityToken": capabilityToken,
                "sessionId": sessionID,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: close)
    }

    nonisolated private static func closeDiscardedSession(request: Data) async {
        await Task.detached(priority: .utility) {
            _ = try? await processPool.run(request: request)
        }.value
    }

    static func isTrustedSidecarFrame(_ frameInfo: WKFrameInfo) -> Bool {
        frameInfo.isMainFrame && isTrustedSidecarURL(frameInfo.request.url)
    }

    static func isTrustedSidecarURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return CmuxDiffViewerURLSchemeHandler.shared.allowsNavigation(to: url)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated fileprivate static func runSidecar(request: Data) async throws -> Data {
        let resources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let sidecar = resources.appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let cmux = resources.appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: sidecar.path),
              FileManager.default.isExecutableFile(atPath: cmux.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let root = try prepareRootDirectory()
        let process = Process()
        process.executableURL = sidecar
        process.arguments = ["rpc", "--root", root.path, "--cmux", cmux.path, "--process-group-ready"]

        let input = Pipe()
        let output = Pipe()
        let readiness = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = readiness

        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        return try await withTaskCancellationHandler {
            try process.run()
            let startup = await waitForProcessGroupReady(
                process: process,
                input: input,
                output: output,
                readiness: readiness
            )
            guard case .ready(true) = startup else {
                await terminateAndReap(
                    process: process,
                    input: input,
                    output: output,
                    readiness: readiness,
                    termination: termination,
                    processGroupID: nil
                )
                if case .cancelled = startup {
                    throw CancellationError()
                }
                throw InvocationError.timedOut
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: request)
                try input.fileHandleForWriting.close()
            } catch {
                await terminateAndReap(
                    process: process,
                    input: input,
                    output: output,
                    readiness: readiness,
                    termination: termination,
                    processGroupID: process.processIdentifier
                )
                throw error
            }

            let outputTask = Task.detached(priority: .userInitiated) {
                output.fileHandleForReading.readDataToEndOfFile()
            }

            let completion = await withTaskGroup(of: InvocationCompletion.self) { group in
                group.addTask {
                    for await status in termination {
                        return .terminated(status)
                    }
                    return Task.isCancelled ? .cancelled : .missingTermination
                }
                group.addTask {
                    do {
                        try await ContinuousClock().sleep(for: .seconds(requestTimeout))
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }
                guard let completion = await group.next() else {
                    return InvocationCompletion.missingTermination
                }
                group.cancelAll()
                return completion
            }
            switch completion {
            case .timedOut, .cancelled:
                await terminateAndReap(
                    process: process,
                    input: input,
                    output: output,
                    readiness: readiness,
                    termination: termination,
                    processGroupID: process.processIdentifier
                )
            case .ready, .terminated, .missingTermination:
                break
            }
            let outputData = await outputTask.value

            let status: Int32
            switch completion {
            case .ready:
                throw InvocationError.missingTermination
            case .terminated(let terminationStatus):
                status = terminationStatus
            case .timedOut:
                throw InvocationError.timedOut
            case .missingTermination:
                throw InvocationError.missingTermination
            case .cancelled:
                throw CancellationError()
            }

            guard status == 0,
                  !outputData.isEmpty,
                  outputData.count <= maximumResponseBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return outputData
        } onCancel: {
            requestTermination(process: process, input: input, output: output, readiness: readiness)
        }
    }

    nonisolated private static func waitForProcessGroupReady(
        process: Process,
        input: Pipe,
        output: Pipe,
        readiness: Pipe
    ) async -> InvocationCompletion {
        let readTask = Task.detached(priority: .userInitiated) {
            (try? readProcessGroupReady(from: readiness.fileHandleForReading)) != nil
        }
        return await withTaskGroup(of: InvocationCompletion.self) { group in
            group.addTask { .ready(await readTask.value) }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: .seconds(startupTimeout))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let completion = await group.next() ?? .missingTermination
            if case .ready(true) = completion {
                // The request can now be sent without racing process-group setup.
            } else {
                requestTermination(process: process, input: input, output: output, readiness: readiness)
            }
            group.cancelAll()
            return completion
        }
    }

    nonisolated private static func readProcessGroupReady(from handle: FileHandle) throws {
        var received = Data()
        while received.count < processGroupReadyMarker.count {
            let remaining = processGroupReadyMarker.count - received.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            received.append(chunk)
        }
        guard received == processGroupReadyMarker else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    nonisolated private static func requestTermination(
        process: Process,
        input: Pipe,
        output: Pipe,
        readiness: Pipe
    ) {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? readiness.fileHandleForReading.close()
        if process.isRunning {
            let processID = process.processIdentifier
            if processID > 0, Darwin.getpgid(processID) == processID {
                killProcessGroup(process, signal: SIGTERM)
            } else {
                process.terminate()
            }
        }
    }

    nonisolated private static func terminateAndReap(
        process: Process,
        input: Pipe,
        output: Pipe,
        readiness: Pipe,
        termination: AsyncStream<Int32>,
        processGroupID: pid_t?
    ) async {
        let processID = process.processIdentifier
        let confirmedProcessGroupID = processGroupID ?? (
            processID > 0 && Darwin.getpgid(processID) == processID ? processID : nil
        )
        requestTermination(process: process, input: input, output: output, readiness: readiness)
        let terminated = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in termination {
                    return true
                }
                return !process.isRunning
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: .seconds(terminationGrace))
                } catch {
                    return !process.isRunning
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if let confirmedProcessGroupID {
            _ = Darwin.kill(-confirmedProcessGroupID, SIGKILL)
        } else if !terminated, process.isRunning {
            forceTermination(process)
        }
        process.waitUntilExit()
    }

    nonisolated private static func forceTermination(_ process: Process) {
        let processID = process.processIdentifier
        guard processID > 0 else { return }
        if Darwin.getpgid(processID) == processID {
            killProcessGroup(process, signal: SIGKILL)
        } else {
            _ = Darwin.kill(processID, SIGKILL)
        }
    }

    nonisolated private static func killProcessGroup(_ process: Process, signal: Int32) {
        let processGroup = process.processIdentifier
        guard processGroup > 0 else { return }
        _ = Darwin.kill(-processGroup, signal)
    }

    nonisolated private static func prepareRootDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private static func failureResponse(body: Any, code: String, message: String) -> [String: Any] {
        let request = body as? [String: Any]
        return [
            "id": request?["id"] as? String ?? "unknown",
            "version": request?["version"] as? Int ?? 1,
            "result": NSNull(),
            "error": ["code": code, "message": message],
        ]
    }
}

actor DiffSidecarProcessPool {
    private enum PoolError: Error { case queueFull }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private let queueLimit = 32
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func run(request: Data) async throws -> Data {
        try await withPermit {
            try await DiffSidecarBridge.runSidecar(request: request)
        }
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }
        guard waiters.count < queueLimit else { throw PoolError.queueFull }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard granted else {
            throw CancellationError()
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            activeCount -= 1
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }
}

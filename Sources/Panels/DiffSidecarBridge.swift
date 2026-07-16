import Foundation
import WebKit

/// Reply-capable transport for the Rust diff sidecar. Requests share one
/// app-scoped child over bounded stdin/stdout frames. The sidecar never opens a
/// socket, and WebKit never receives filesystem paths or process access.
@MainActor
final class DiffSidecarBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxDiff"
    static let shared = DiffSidecarBridge()

    private static var handlerInstalledKey: UInt8 = 0
    private static let maximumRequestBytes = 1024 * 1024
    private nonisolated static let processPool = DiffSidecarProcessPool(limit: 4)
    private nonisolated static let sidecarProcess = DiffSidecarProcessSupervisor()
    private static let pendingSessionID = "00000000-0000-0000-0000-000000000000"
    private struct ViewerInvocationKey: Hashable {
        let webView: ObjectIdentifier
        let token: String
    }
    private var invocations: [UUID: Task<Void, Never>] = [:]
    private var sessionInvocationByViewer: [ViewerInvocationKey: UUID] = [:]
    private var discardedSessionInvocations: Set<UUID> = []

    nonisolated static func shutdown() {
        Task.detached(priority: .utility) {
            await sidecarProcess.shutdown()
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

    nonisolated fileprivate static func runSidecar(request: Data) async throws -> Data {
        try await sidecarProcess.run(request: request)
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

actor DiffSidecarProcessSupervisor {
    private enum SupervisorError: Error {
        case duplicateRequest
        case invalidRequest
        case invalidResponse
        case startupTimedOut
        case requestTimedOut
        case processExited(Int32)
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
        let generation: UInt64
    }

    private static let maximumRequestBytes = 1024 * 1024
    private static let maximumResponseBytes = 32 * 1024 * 1024
    private static let processGroupReadyMarker = Data("cmux-diff-sidecar-process-group-ready\n".utf8)
    private static let startupTimeout: TimeInterval = 5
    // Longer than the sidecar's 120-second branch regeneration limit.
    private static let requestTimeout: TimeInterval = 130

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var readiness: Pipe?
    private var startupTask: Task<Void, Error>?
    private var outputTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pending: [String: PendingRequest] = [:]

    func run(request: Data) async throws -> Data {
        let requestID = try Self.requestID(from: request)
        try Task.checkCancellation()
        try await ensureRunning()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await enqueue(request: request, requestID: requestID)
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    func shutdown() {
        stopProcess(error: CancellationError())
    }

    private func ensureRunning() async throws {
        if let process, process.isRunning, outputTask != nil {
            return
        }
        if let startupTask {
            return try await startupTask.value
        }
        let task = Task { try await launch() }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            stopProcess(error: error)
            throw error
        }
    }

    private func launch() async throws {
        let resources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let sidecar = resources.appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let cmux = resources.appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: sidecar.path),
              FileManager.default.isExecutableFile(atPath: cmux.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let root = try Self.prepareRootDirectory()
        generation &+= 1
        let launchGeneration = generation
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let readiness = Pipe()
        process.executableURL = sidecar
        process.arguments = ["rpc", "--root", root.path, "--cmux", cmux.path, "--process-group-ready"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = readiness
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.processDidExit(generation: launchGeneration, status: status) }
        }
        self.process = process
        self.input = input
        self.output = output
        self.readiness = readiness

        try process.run()
        try await Self.waitForProcessGroupReady(from: readiness.fileHandleForReading)

        let outputHandle = output.fileHandleForReading
        outputTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var frame = Data()
                for try await byte in outputHandle.bytes {
                    if byte == UInt8(ascii: "\n") {
                        await self?.receive(frame: frame, generation: launchGeneration)
                        frame.removeAll(keepingCapacity: true)
                    } else {
                        frame.append(byte)
                        if frame.count > Self.maximumResponseBytes {
                            throw SupervisorError.invalidResponse
                        }
                    }
                }
                if !frame.isEmpty {
                    throw SupervisorError.invalidResponse
                }
                await self?.outputDidEnd(generation: launchGeneration)
            } catch {
                await self?.transportDidFail(generation: launchGeneration, error: error)
            }
        }
        let readinessHandle = readiness.fileHandleForReading
        stderrTask = Task.detached(priority: .utility) {
            do {
                for try await _ in readinessHandle.bytes {}
            } catch {
                // Process termination closes the diagnostic stream.
            }
        }
    }

    private func enqueue(request: Data, requestID: String) async throws -> Data {
        guard pending[requestID] == nil else { throw SupervisorError.duplicateRequest }
        guard let input, process?.isRunning == true else {
            throw SupervisorError.processExited(-1)
        }
        let requestGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(for: .seconds(Self.requestTimeout))
                    await self?.requestDidTimeOut(requestID: requestID, generation: requestGeneration)
                } catch {
                    // Completing or cancelling a request cancels its deadline.
                }
            }
            pending[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask,
                generation: requestGeneration
            )
            do {
                try Self.write(frame: request, to: input.fileHandleForWriting)
            } catch {
                complete(requestID: requestID, result: .failure(error))
                transportDidFail(generation: requestGeneration, error: error)
            }
        }
    }

    private func receive(frame: Data, generation: UInt64) {
        guard generation == self.generation,
              !frame.isEmpty,
              frame.count <= Self.maximumResponseBytes,
              let requestID = try? Self.requestID(from: frame, maximumBytes: Self.maximumResponseBytes),
              pending[requestID]?.generation == generation else {
            return
        }
        complete(requestID: requestID, result: .success(frame))
    }

    private func cancel(requestID: String) {
        guard pending[requestID] != nil else { return }
        sendCancellation(requestID: requestID)
        complete(requestID: requestID, result: .failure(CancellationError()))
    }

    private func requestDidTimeOut(requestID: String, generation: UInt64) {
        guard pending[requestID]?.generation == generation else { return }
        sendCancellation(requestID: requestID)
        complete(requestID: requestID, result: .failure(SupervisorError.requestTimedOut))
    }

    private func sendCancellation(requestID: String) {
        guard let input, process?.isRunning == true,
              let frame = try? JSONSerialization.data(withJSONObject: [
                  "control": "cancel",
                  "requestId": requestID,
              ]) else { return }
        try? Self.write(frame: frame, to: input.fileHandleForWriting)
    }

    private func complete(requestID: String, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func processDidExit(generation: UInt64, status: Int32) {
        guard generation == self.generation else { return }
        stopProcess(error: SupervisorError.processExited(status))
    }

    private func outputDidEnd(generation: UInt64) {
        guard generation == self.generation, process?.isRunning != true else { return }
        stopProcess(error: SupervisorError.processExited(process?.terminationStatus ?? -1))
    }

    private func transportDidFail(generation: UInt64, error: Error) {
        guard generation == self.generation else { return }
        stopProcess(error: error)
    }

    private func stopProcess(error: Error) {
        generation &+= 1
        startupTask?.cancel()
        startupTask = nil
        outputTask?.cancel()
        outputTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        try? readiness?.fileHandleForReading.close()
        if let process, process.isRunning {
            Self.terminate(process)
        }
        process?.terminationHandler = nil
        process = nil
        input = nil
        output = nil
        readiness = nil
        let pendingRequests = Array(pending.values)
        pending.removeAll()
        for request in pendingRequests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private nonisolated static func requestID(
        from frame: Data,
        maximumBytes: Int = maximumRequestBytes
    ) throws -> String {
        guard frame.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let requestID = object["id"] as? String,
              !requestID.isEmpty else {
            throw SupervisorError.invalidRequest
        }
        return requestID
    }

    private nonisolated static func write(frame: Data, to handle: FileHandle) throws {
        guard !frame.isEmpty, frame.count <= maximumRequestBytes else {
            throw SupervisorError.invalidRequest
        }
        var framed = frame
        framed.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: framed)
    }

    private nonisolated static func waitForProcessGroupReady(from handle: FileHandle) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var received = Data()
                for try await byte in handle.bytes {
                    received.append(byte)
                    if received.count == processGroupReadyMarker.count {
                        guard received == processGroupReadyMarker else {
                            throw SupervisorError.invalidResponse
                        }
                        return
                    }
                }
                throw SupervisorError.invalidResponse
            }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(startupTimeout))
                throw SupervisorError.startupTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private nonisolated static func terminate(_ process: Process) {
        let processID = process.processIdentifier
        guard processID > 0 else { return }
        if Darwin.getpgid(processID) == processID {
            _ = Darwin.kill(-processID, SIGTERM)
        } else {
            process.terminate()
        }
    }

    private nonisolated static func prepareRootDirectory() throws -> URL {
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

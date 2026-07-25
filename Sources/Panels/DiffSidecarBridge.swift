import Foundation
import WebKit

actor DiffSidecarProcessExitSignal {
    private var exited = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func markExited() {
        guard !exited else { return }
        exited = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !exited, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if exited || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

final class DiffSidecarSynchronousTerminationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: Int32?

    func register(processID: Int32) {
        guard processID > 0 else { return }
        lock.lock()
        self.processID = processID
        lock.unlock()
    }

    func clear(processID: Int32) {
        lock.lock()
        if self.processID == processID {
            self.processID = nil
        }
        lock.unlock()
    }

    func terminateSynchronously() {
        lock.lock()
        let processID = self.processID
        self.processID = nil
        lock.unlock()
        guard let processID, processID > 0 else { return }
        if Darwin.getpgid(processID) == processID {
            _ = Darwin.kill(-processID, SIGTERM)
        } else {
            _ = Darwin.kill(processID, SIGTERM)
        }
    }
}

/// Ordered, bounded writer for the sidecar's stdin pipe.
///
/// Pipe writes must never run on ``DiffSidecarProcessSupervisor``'s actor:
/// a living child that stops draining stdin can fill the pipe and otherwise
/// prevent that actor from running its timeout, cancellation, and shutdown
/// paths. This writer uses a dedicated serial queue plus a nonblocking
/// descriptor and a short poll deadline, preserving request order without
/// pinning the supervisor.
final class DiffSidecarFrameWriter: @unchecked Sendable {
    enum WriterError: Error, Equatable {
        case invalidRequest
        case timedOut
    }

    private final class OperationState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var terminalResult: Result<Void, Error>?
        private var cancelled = false

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let terminalResult {
                lock.unlock()
                continuation.resume(with: terminalResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard terminalResult == nil else {
                lock.unlock()
                return
            }
            terminalResult = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            finish(.failure(CancellationError()))
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    private static let maximumRequestBytes = 1024 * 1024
    private let queue: DispatchQueue
    private let fileDescriptor: Int32

    init(handle: FileHandle, label: String = "com.cmux.diff-sidecar.stdin") throws {
        let fileDescriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Self.currentPOSIXError()
        }
        self.fileDescriptor = fileDescriptor
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func write(frame: Data, timeout: TimeInterval) async throws {
        guard !frame.isEmpty,
              frame.count <= Self.maximumRequestBytes,
              timeout > 0 else {
            throw WriterError.invalidRequest
        }
        let framed: Data = {
            var data = frame
            data.append(UInt8(ascii: "\n"))
            return data
        }()
        let operation = OperationState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                queue.async { [fileDescriptor] in
                    do {
                        try Self.writeFully(
                            framed,
                            to: fileDescriptor,
                            timeout: timeout,
                            operation: operation
                        )
                        operation.finish(.success(()))
                    } catch {
                        operation.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    /// Waits until every previously submitted write has left the serial queue.
    /// Call this only after the child has exited, so a pipe with backpressure is
    /// guaranteed to wake with `EPIPE`.
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private static func writeFully(
        _ data: Data,
        to fileDescriptor: Int32,
        timeout: TimeInterval,
        operation: OperationState
    ) throws {
        let timeoutNanoseconds = UInt64(min(timeout, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started.addingReportingOverflow(timeoutNanoseconds)
        let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw WriterError.invalidRequest
            }
            var offset = 0
            while offset < rawBuffer.count {
                if operation.isCancelled {
                    throw CancellationError()
                }
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    throw POSIXError(.EPIPE)
                }
                if errno == EINTR {
                    continue
                }
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw currentPOSIXError()
                }

                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    throw WriterError.timedOut
                }
                let remainingMilliseconds = max(
                    1,
                    Int(min((deadlineNanoseconds - now) / 1_000_000, 50))
                )
                var descriptor = pollfd(
                    fd: fileDescriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let pollResult = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
                if pollResult < 0, errno != EINTR {
                    throw currentPOSIXError()
                }
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    throw POSIXError(.EBADF)
                }
                if descriptor.revents & Int16(POLLERR | POLLHUP) != 0 {
                    throw POSIXError(.EPIPE)
                }
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

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
    private nonisolated static let terminationHandle = DiffSidecarSynchronousTerminationHandle()
    private nonisolated static let sidecarProcess = DiffSidecarProcessSupervisor(
        terminationHandle: terminationHandle
    )
    private static let pendingSessionID = "00000000-0000-0000-0000-000000000000"
    private struct ViewerInvocationKey: Hashable {
        let webView: ObjectIdentifier
        let token: String
        let viewerInstanceID: String
    }
    private var invocations: [UUID: Task<Void, Never>] = [:]
    private var sessionInvocationByViewer: [ViewerInvocationKey: UUID] = [:]
    private var discardedSessionInvocations: Set<UUID> = []

    nonisolated static func shutdown() {
        terminationHandle.terminateSynchronously()
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
        let viewerInstanceID = Self.viewerInstanceID(from: body)
        let viewerKey: ViewerInvocationKey?
        if let webView = message.webView, let viewerToken, let viewerInstanceID {
            viewerKey = ViewerInvocationKey(
                webView: ObjectIdentifier(webView),
                token: viewerToken,
                viewerInstanceID: viewerInstanceID
            )
        } else {
            viewerKey = nil
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

    nonisolated static func viewerInstanceID(from body: [String: Any]) -> String? {
        guard let params = body["params"] as? [String: Any],
              let rawValue = params["viewerInstanceId"] as? String,
              let value = UUID(uuidString: rawValue) else {
            return nil
        }
        return value.uuidString.lowercased()
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
    // Longer than the sidecar's 120-second branch regeneration limit.
    private static let requestTimeout: TimeInterval = 130
    // A healthy sidecar continuously drains stdin; pipe backpressure for this
    // long means the transport is wedged and should be restarted.
    private static let writeTimeout: TimeInterval = 2

    private var process: Process?
    private var input: Pipe?
    private var writer: DiffSidecarFrameWriter?
    private var output: Pipe?
    private var readiness: Pipe?
    private var startupTask: Task<Void, Error>?
    private var outputTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var generation: UInt64 = 0
    private var pending: [String: PendingRequest] = [:]
    private let terminationHandle: DiffSidecarSynchronousTerminationHandle

    init(terminationHandle: DiffSidecarSynchronousTerminationHandle = .init()) {
        self.terminationHandle = terminationHandle
    }

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

    func shutdown() async {
        await stopProcess(error: CancellationError())
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
            await stopProcess(error: error)
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
        self.writer = try DiffSidecarFrameWriter(handle: input.fileHandleForWriting)
        self.output = output
        self.readiness = readiness

        try process.run()
        terminationHandle.register(processID: process.processIdentifier)
        try await Self.waitForProcessGroupReady(from: readiness.fileHandleForReading)

        let outputHandle = output.fileHandleForReading
        let outputStream = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        outputContinuation = outputStream.continuation
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputStream.continuation.finish()
            } else {
                outputStream.continuation.yield(data)
            }
        }
        outputTask = Task { [weak self] in
            var frame = Data()
            for await data in outputStream.stream {
                var searchStart = data.startIndex
                while let newlineIndex = data[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
                    frame.append(contentsOf: data[searchStart..<newlineIndex])
                    if frame.count > Self.maximumResponseBytes {
                        await self?.transportDidFail(
                            generation: launchGeneration,
                            error: SupervisorError.invalidResponse
                        )
                        return
                    }
                    await self?.receive(frame: frame, generation: launchGeneration)
                    frame.removeAll(keepingCapacity: true)
                    searchStart = data.index(after: newlineIndex)
                }
                frame.append(contentsOf: data[searchStart...])
                if frame.count > Self.maximumResponseBytes {
                    await self?.transportDidFail(
                        generation: launchGeneration,
                        error: SupervisorError.invalidResponse
                    )
                    return
                }
            }
            if !frame.isEmpty {
                await self?.transportDidFail(
                    generation: launchGeneration,
                    error: SupervisorError.invalidResponse
                )
                return
            }
            await self?.outputDidEnd(generation: launchGeneration)
        }
        let readinessHandle = readiness.fileHandleForReading
        readinessHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func enqueue(request: Data, requestID: String) async throws -> Data {
        guard pending[requestID] == nil else { throw SupervisorError.duplicateRequest }
        guard let writer, process?.isRunning == true else {
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
            Task { [weak self] in
                await self?.writeRequest(
                    request,
                    requestID: requestID,
                    generation: requestGeneration,
                    writer: writer
                )
            }
        }
    }

    private func writeRequest(
        _ request: Data,
        requestID: String,
        generation: UInt64,
        writer: DiffSidecarFrameWriter
    ) async {
        do {
            try await writer.write(frame: request, timeout: Self.writeTimeout)
        } catch {
            guard pending[requestID]?.generation == generation else { return }
            complete(requestID: requestID, result: .failure(error))
            await transportDidFail(generation: generation, error: error)
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
        guard let request = pending[requestID] else { return }
        complete(requestID: requestID, result: .failure(CancellationError()))
        Task { [weak self] in
            await self?.sendCancellation(requestID: requestID, generation: request.generation)
        }
    }

    private func requestDidTimeOut(requestID: String, generation: UInt64) {
        guard pending[requestID]?.generation == generation else { return }
        complete(requestID: requestID, result: .failure(SupervisorError.requestTimedOut))
        // `complete` cancels the deadline task that called this method. Send the
        // cancellation from a fresh task so that cancellation does not
        // immediately abort the writer and restart an otherwise healthy child.
        Task { [weak self] in
            await self?.sendCancellation(requestID: requestID, generation: generation)
        }
    }

    private func sendCancellation(requestID: String, generation: UInt64) async {
        guard generation == self.generation,
              let writer,
              process?.isRunning == true,
              let frame = try? JSONSerialization.data(withJSONObject: [
                  "control": "cancel",
                  "requestId": requestID,
              ]) else { return }
        do {
            try await writer.write(frame: frame, timeout: Self.writeTimeout)
        } catch {
            await transportDidFail(generation: generation, error: error)
        }
    }

    private func complete(requestID: String, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func processDidExit(generation: UInt64, status: Int32) async {
        guard generation == self.generation else { return }
        await stopProcess(error: SupervisorError.processExited(status))
    }

    private func outputDidEnd(generation: UInt64) async {
        guard generation == self.generation else { return }
        await stopProcess(error: SupervisorError.processExited(process?.terminationStatus ?? -1))
    }

    private func transportDidFail(generation: UInt64, error: Error) async {
        guard generation == self.generation else { return }
        await stopProcess(error: error)
    }

    private func stopProcess(error: Error) async {
        generation &+= 1
        startupTask?.cancel()
        startupTask = nil
        output?.fileHandleForReading.readabilityHandler = nil
        readiness?.fileHandleForReading.readabilityHandler = nil
        outputContinuation?.finish()
        outputContinuation = nil
        outputTask?.cancel()
        outputTask = nil
        let inputToClose = input
        let writerToDrain = writer
        let outputToClose = output
        let readinessToClose = readiness
        let processToReap = process
        if let processToReap {
            terminationHandle.clear(processID: processToReap.processIdentifier)
        }
        processToReap?.terminationHandler = nil
        process = nil
        input = nil
        writer = nil
        output = nil
        readiness = nil
        let pendingRequests = Array(pending.values)
        pending.removeAll()
        for request in pendingRequests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
        if let processToReap, processToReap.isRunning {
            await Self.terminateAndReap(processToReap)
        }
        await writerToDrain?.shutdown()
        try? inputToClose?.fileHandleForWriting.close()
        try? outputToClose?.fileHandleForReading.close()
        try? readinessToClose?.fileHandleForReading.close()
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

    nonisolated static func waitForProcessGroupReady(
        from handle: FileHandle,
        timeout: Duration = .seconds(5)
    ) async throws {
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
                try await ContinuousClock().sleep(for: timeout)
                try? handle.close()
                throw SupervisorError.startupTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    nonisolated static func terminateAndReap(
        _ process: Process,
        gracePeriod: Duration = .seconds(1)
    ) async {
        let processID = process.processIdentifier
        guard processID > 0 else { return }
        let exitSignal = DiffSidecarProcessExitSignal()
        process.terminationHandler = { _ in
            Task { await exitSignal.markExited() }
        }
        if !process.isRunning {
            await exitSignal.markExited()
        }
        if Darwin.getpgid(processID) == processID {
            _ = Darwin.kill(-processID, SIGTERM)
        } else {
            process.terminate()
        }
        let exitedDuringGrace = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitSignal.wait()
                return !Task.isCancelled
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: gracePeriod)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !exitedDuringGrace, process.isRunning {
            if Darwin.getpgid(processID) == processID {
                _ = Darwin.kill(-processID, SIGKILL)
            } else {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
        await exitSignal.wait()
        process.terminationHandler = nil
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
